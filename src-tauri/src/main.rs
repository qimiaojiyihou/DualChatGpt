#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tauri::{Manager, State};

#[derive(Serialize, Deserialize)]
struct Status { platform: String, version: String, default: u32, secondary: u32, unknown: u32, message: String }
struct OperationLock(Mutex<()>);

#[cfg(target_os = "windows")]
fn powershell_script_path(path: &str) -> String {
    if let Some(path) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{}", path)
    } else {
        path.strip_prefix(r"\\?\").unwrap_or(path).to_string()
    }
}

#[cfg(target_os = "windows")]
fn perform(app: &tauri::AppHandle, action: &str, client_path: Option<String>) -> Result<Status, String> {
    use std::os::windows::process::CommandExt;
    let script = app.path().resolve("bridge/Bridge.ps1", tauri::path::BaseDirectory::Resource).map_err(|e| e.to_string())?;
    // Windows PowerShell 5 cannot resolve $PSScriptRoot when -File receives an
    // extended-length path, which Tauri can return for bundled resources.
    let script = powershell_script_path(&script.to_string_lossy());
    let mut cmd = std::process::Command::new("powershell.exe");
    cmd.creation_flags(0x08000000).args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"]).arg(script).arg("-Action").arg(action);
    if let Some(path) = client_path.filter(|s| !s.trim().is_empty()) { cmd.arg("-ClientPath").arg(path); }
    let output = cmd.output().map_err(|e| format!("启动系统检查失败：{e}"))?;
    let text = String::from_utf8_lossy(&output.stdout);
    let json: serde_json::Value = serde_json::from_str(text.trim().trim_start_matches('\u{feff}')).map_err(|_| {
        let detail = String::from_utf8_lossy(&output.stderr).trim().chars().take(700).collect::<String>();
        if detail.is_empty() { "系统检查未返回有效结果，请确认 Windows PowerShell 可用。".to_string() }
        else { format!("系统检查启动失败：{detail}") }
    })?;
    if !output.status.success() { return Err(json.get("error").and_then(|v| v.as_str()).unwrap_or("系统检查失败。").to_string()); }
    serde_json::from_value(json).map_err(|e| format!("解析检查结果失败：{e}"))
}

#[cfg(all(test, target_os = "windows"))]
mod windows_tests {
    use super::powershell_script_path;

    #[test]
    fn powershell_receives_normal_drive_and_unc_paths() {
        assert_eq!(powershell_script_path(r"\\?\C:\App\Bridge.ps1"), r"C:\App\Bridge.ps1");
        assert_eq!(powershell_script_path(r"\\?\UNC\server\share\Bridge.ps1"), r"\\server\share\Bridge.ps1");
        assert_eq!(powershell_script_path(r"C:\App\Bridge.ps1"), r"C:\App\Bridge.ps1");
    }
}

#[cfg(target_os = "macos")]
fn perform(_app: &tauri::AppHandle, action: &str, client_path: Option<String>) -> Result<Status, String> {
    macos::perform(action, client_path)
}
#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn perform(_app: &tauri::AppHandle, _action: &str, _client_path: Option<String>) -> Result<Status, String> {
    Err("当前支持 Windows 和 macOS。".into())
}

#[tauri::command]
async fn check_status(app: tauri::AppHandle, state: State<'_, OperationLock>, client_path: Option<String>) -> Result<Status, String> {
    let _guard = state.0.try_lock().map_err(|_| "正在执行另一项操作，请稍候。".to_string())?;
    perform(&app, "status", client_path)
}
#[tauri::command]
async fn launch_secondary(app: tauri::AppHandle, state: State<'_, OperationLock>, client_path: Option<String>) -> Result<Status, String> {
    let _guard = state.0.try_lock().map_err(|_| "正在执行另一项操作，请稍候。".to_string())?;
    perform(&app, "launch", client_path)
}
fn main() {
    tauri::Builder::default().manage(OperationLock(Mutex::new(())))
        .invoke_handler(tauri::generate_handler![check_status, launch_secondary])
        .run(tauri::generate_context!()).expect("运行 DualChatGPT 失败");
}

#[cfg(target_os = "macos")]
mod macos {
    use super::Status;
    use std::{fs, io::Read, os::unix::fs::PermissionsExt, path::{Path, PathBuf}, process::Command, thread, time::{Duration, Instant}};
    fn command(program: &str, args: &[&str]) -> Result<std::process::Output, String> { Command::new(program).args(args).output().map_err(|e| e.to_string()) }
    fn plain(path: &Path) -> Result<(), String> {
        for ancestor in path.ancestors() {
            match fs::symlink_metadata(ancestor) { Ok(m) if m.file_type().is_symlink() => return Err("数据目录包含符号链接，请检查后重试。".into()), Ok(_) => (), Err(e) if e.kind() == std::io::ErrorKind::NotFound => (), Err(e) => return Err(e.to_string()) }
        } Ok(())
    }
    fn token(path: &Path, needle: &[u8]) -> Result<bool, String> {
        let mut f=fs::File::open(path).map_err(|_| "未找到客户端程序资源。".to_string())?;
        let mut buf=vec![0; 1024*1024]; let mut tail=Vec::new();
        loop { let n=f.read(&mut buf).map_err(|e| e.to_string())?; if n==0 {return Ok(false)} tail.extend_from_slice(&buf[..n]); if tail.windows(needle.len()).any(|w|w==needle) { return Ok(true) } let keep=needle.len().min(tail.len()); tail=tail[tail.len()-keep..].to_vec(); }
    }
    fn identify(path: Option<String>) -> Result<(PathBuf,String),String> {
        let app=match path.filter(|s|!s.trim().is_empty()) {Some(p)=>PathBuf::from(p), None=>["/Applications/Codex.app","/Applications/ChatGPT.app"].iter().map(PathBuf::from).find(|p|p.exists()).ok_or("未找到官方客户端，请在设置中填写 .app 的完整路径。")?};
        if app.extension().and_then(|x|x.to_str()) != Some("app") {return Err("请选择官方客户端的 .app 目录。".into())}
        plain(&app)?;
        let path=app.to_str().ok_or("客户端路径格式不受支持。")?;
        let verify=command("/usr/bin/codesign", &["--verify","--deep","--strict",path])?;
        if !verify.status.success() { return Err("客户端签名校验未通过。".into()) }
        let details=command("/usr/bin/codesign", &["-dv","--verbose=4",path])?;
        let info=String::from_utf8_lossy(&details.stderr);
        if !details.status.success() || !info.lines().any(|l|l.starts_with("Authority=Developer ID Application: OpenAI")) { return Err("未识别到 OpenAI 开发者签名。".into()) }
        let archive=app.join("Contents/Resources/app.asar");
        if !token(&archive,b"CODEX_ELECTRON_USER_DATA_PATH")? {return Err("客户端缺少所需的独立目录开关。".into())}
        let plist=app.join("Contents/Info.plist");
        let out=command("/usr/libexec/PlistBuddy", &["-c","Print :CFBundleExecutable",plist.to_str().ok_or("路径无效")?])?;
        if !out.status.success() {return Err("读取客户端程序信息失败。".into())}
        let name=String::from_utf8_lossy(&out.stdout).trim().to_string();
        if name.contains('/') || name.is_empty() {return Err("客户端程序名称无效。".into())}
        let exe=app.join("Contents/MacOS").join(name);
        if !exe.is_file() {return Err("客户端程序不存在。".into())}
        let version_out=command("/usr/libexec/PlistBuddy", &["-c","Print :CFBundleShortVersionString",plist.to_str().ok_or("路径无效")?])?;
        Ok((exe,String::from_utf8_lossy(&version_out.stdout).trim().to_string()))
    }
    fn count(exe:&Path, electron:&Path) -> Result<(u32,u32,u32),String> {
        let output=command("/bin/ps", &["-axo","command="])?;
        if !output.status.success() {return Err("读取进程状态失败。".into())}
        let exe=exe.to_str().ok_or("路径无效")?; let profile=electron.to_str().ok_or("路径无效")?;
        let (mut a,mut b,mut u)=(0,0,0);
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let line=line.trim(); if !line.starts_with(exe) || line.contains("--type=") {continue}
            if line.contains("--user-data-dir=") && line.contains(profile) {b+=1} else if line.contains("--user-data-dir") {u+=1} else {a+=1}
        } Ok((a,b,u))
    }
    fn prepare(root:&Path) -> Result<(),String> {
        plain(root)?;
        if root.exists() && !root.join("isolation.json").exists() && fs::read_dir(root).map_err(|e|e.to_string())?.next().is_some() {return Err("数据目录已有未知内容，请先检查。".into())}
        fs::create_dir_all(root).map_err(|e|e.to_string())?;
        fs::set_permissions(root,fs::Permissions::from_mode(0o700)).map_err(|e|e.to_string())?;
        let marker=root.join("isolation.json"); plain(&marker)?;
        let expected="{\"format\":1,\"application\":\"DualChatGPT\"}";
        if marker.exists() { if fs::read_to_string(&marker).map_err(|e|e.to_string())? != expected {return Err("数据目录标识不匹配。".into())} } else {fs::write(&marker,expected).map_err(|e|e.to_string())?;}
        let base=root.join("B");
        for name in ["electron","codex","sqlite","temp","work"] { let dir=base.join(name); plain(&dir)?; fs::create_dir_all(dir).map_err(|e|e.to_string())?; }
        let config=base.join("codex/config.toml"); plain(&config)?;
        let sqlite=base.join("sqlite").to_string_lossy().replace('\\',"\\\\").replace('"',"\\\"");
        let expected=format!("cli_auth_credentials_store = \"file\"\nsqlite_home = \"{}\"\n",sqlite);
        if config.exists() {if fs::read_to_string(config).map_err(|e|e.to_string())? != expected {return Err("第二窗口的配置已变更，请检查后重试。".into())}} else {fs::write(config,expected).map_err(|e|e.to_string())?;}
        Ok(())
    }
    pub fn perform(action:&str, path:Option<String>) -> Result<Status,String> {
        let (exe,version)=identify(path)?;
        let home=std::env::var_os("HOME").ok_or("未找到用户目录。")?;
        let root=PathBuf::from(home).join("Library/Application Support/DualChatGPT/profiles"); let base=root.join("B"); let electron=base.join("electron");
        let (mut a,mut b,mut u)=count(&exe,&electron)?;
        let mut message="客户端已就绪。macOS 双账号功能仍需实机验收。".to_string();
        if action=="launch" {
            if u>0 || a>1 || b>1 {return Err("发现未识别或重复的客户端进程，请先检查。".into())}
            if b==1 {message="第二窗口已经运行，请切换到该窗口。".into()} else {
                prepare(&root)?;
                let state=count(&exe,&electron)?; if state.0>1 || state.1>0 || state.2>0 {return Err("客户端状态发生变化，请重试。".into())}
                let mut cmd=Command::new(&exe); cmd.arg(format!("--user-data-dir={}",electron.display())).current_dir(base.join("work"));
                for (key,_) in std::env::vars_os() {let s=key.to_string_lossy().to_ascii_uppercase(); if ["CODEX_","OPENAI_","AZURE_OPENAI_","ELECTRON_","CHATGPT_"].iter().any(|p|s.starts_with(p)) || ["NODE_OPTIONS","NODE_PATH","ANTHROPIC_API_KEY"].contains(&s.as_str()) {cmd.env_remove(key);}}
                cmd.env("CODEX_HOME",base.join("codex")).env("CODEX_SQLITE_HOME",base.join("sqlite")).env("CODEX_ELECTRON_USER_DATA_PATH",&electron).env("TMPDIR",base.join("temp"));
                cmd.spawn().map_err(|e|format!("启动失败：{e}"))?;
                let until=Instant::now()+Duration::from_secs(30); loop {thread::sleep(Duration::from_millis(500)); (a,b,u)=count(&exe,&electron)?; if b==1 && a<=1 && u==0 {break} if Instant::now()>until || b>1 || u>0 {return Err("未确认第二窗口的独立进程，请先检查新窗口。".into())}}
                message="第二窗口进程已启动。请在官方窗口登录并核对账号。".into();
            }
        }
        Ok(Status{platform:"macOS".into(),version,default:a,secondary:b,unknown:u,message})
    }
}
