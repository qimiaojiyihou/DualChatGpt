<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { invoke } from '@tauri-apps/api/core';
import { ArrowUpRight, Check, ChevronDown, CircleHelp, ExternalLink, RefreshCw, Settings2, ShieldCheck, Sparkles, Stars, X } from 'lucide-vue-next';
import { resultText, stateLabel, type Status } from './model';
const status = ref<Status | null>(null);
const busy = ref(false); const error = ref(''); const notice = ref(''); const settings = ref(false); const help = ref(false);
const savedPath = ref(localStorage.getItem('clientPath') || ''); const draftPath = ref(savedPath.value);
const clientPath = computed(() => savedPath.value.trim() || null);
const runtime = '__TAURI_INTERNALS__' in window;
async function operation(action: 'check_status' | 'launch_secondary' | 'close_secondary', silent = false) {
  if (busy.value) return;
  if (!runtime) { error.value = '请在 DualChatGPT 桌面应用中使用此功能。'; return; }
  busy.value = true; if (!silent) { error.value = ''; notice.value = ''; }
  try { const result = await invoke<Status>(action, { clientPath: clientPath.value }); status.value = result; error.value = ''; if (action !== 'check_status') notice.value = resultText(result); }
  catch (e) { error.value = String(e); }
  finally { busy.value = false; }
}
function saveSettings() { savedPath.value = draftPath.value.trim(); localStorage.setItem('clientPath', savedPath.value); settings.value = false; void operation('check_status'); }
let timer: ReturnType<typeof setInterval> | undefined;
onMounted(() => { void operation('check_status'); timer = setInterval(() => { if (!document.hidden && !settings.value && !help.value) void operation('check_status', true); }, 30000); });
onUnmounted(() => { if (timer) clearInterval(timer); });
</script>
<template>
  <main class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span class="brand-icon"><Sparkles :size="21" /></span><span><strong>DualChatGPT</strong><small>YOUR CHAT COMPANION</small></span></div>
      <div class="side-label">YOUR SPACE</div>
      <div class="nav-active"><span class="nav-spark">✦</span> 账号窗口 <span class="nav-dot"></span></div>
      <div class="side-illustration"><div class="sparkle spark-one">✦</div><div class="sparkle spark-two">✧</div><img src="/mascot.png" alt=""/><div class="side-note"><b>两个账号，</b><br/>都在你的掌控中 <span>✦</span></div></div>
      <div class="sidebar-bottom"><button class="text-button" @click="help = true"><CircleHelp :size="17"/> 使用帮助</button><button class="text-button" @click="settings = true; draftPath = savedPath"><Settings2 :size="17"/> 设置</button></div>
    </aside>
    <section class="workspace">
      <header class="topbar"><div><span class="eyebrow">YOUR LITTLE WORKSPACE <span>✦</span></span><h1>欢迎回来 <span>✧</span></h1><p>两个账号，轻松切换，各自保留自己的空间。</p></div><button class="icon-button" aria-label="打开设置" title="设置" @click="settings = true; draftPath = savedPath"><Settings2 :size="19"/></button></header>
      <div class="section-heading"><div><span class="section-kicker">ACCOUNT WINDOWS</span><h2>账号窗口 <span class="section-star">✦</span></h2></div><button class="refresh" :disabled="busy" @click="operation('check_status')"><RefreshCw :size="15" :class="{spinning: busy}"/> 刷新状态</button></div>
      <div v-if="error" class="banner error" role="alert"><span>!</span><div>{{ error }} <button class="inline-link" @click="settings = true; draftPath = savedPath">检查设置</button></div><button class="dismiss" aria-label="关闭提示" @click="error = ''"><X :size="16"/></button></div>
      <div v-if="notice" class="banner success" role="status"><Check :size="17"/><div>{{ notice }}</div><button class="dismiss" aria-label="关闭提示" @click="notice = ''"><X :size="16"/></button></div>
      <div class="account-grid">
        <article class="account-card original"><div class="card-top"><div class="avatar avatar-original"><span>✦</span></div><span class="badge" :class="{ online: status?.default === 1 }"><i></i>{{ status ? stateLabel(status.default) : '等待检查' }}</span></div><div class="card-index">01 / ORIGINAL</div><h3>原账号窗口</h3><p>熟悉的账号与原有聊天，<br/>都在这里。</p><div class="card-foot"><span class="foot-icon"><ShieldCheck :size="16"/></span><span>使用原有数据</span></div></article>
        <article class="account-card second"><div class="card-top"><div class="avatar avatar-second"><span>✧</span></div><span class="badge" :class="{ online: status?.secondary === 1 && status?.secondaryVisible !== false }"><i></i>{{ !status ? '等待检查' : status.secondary === 1 && status.secondaryVisible === false ? '后台运行' : stateLabel(status.secondary) }}</span></div><div class="card-index">02 / SECOND SPACE</div><h3>第二账号窗口</h3><p>为另一个账号留一片<br/>独立的小天地。</p><div class="card-actions"><button class="launch" :disabled="busy || (status?.unknown ?? 0) > 0" @click="operation('launch_secondary')">{{ busy ? '正在处理…' : status?.secondary === 1 && status?.secondaryVisible !== false ? '显示第二窗口' : '打开第二窗口' }} <ArrowUpRight :size="17"/></button><button v-if="status?.platform === 'Windows' && status.secondaryVisible" class="close-window" :disabled="busy || status.unknown > 0" @click="operation('close_secondary')">关闭窗口</button></div></article>
      </div>
      <div class="guide"><div class="guide-icon"><Stars :size="19"/></div><div><b>第一次使用？</b><p>先正常打开原窗口，再打开第二窗口，并在官方登录页选择另一个账号。</p></div><button @click="help = true">查看指南 <ArrowUpRight :size="15"/></button></div>
      <footer><span><i class="footer-dot"></i>{{ status ? `${status.platform} · 客户端 ${status.version || '已就绪'}` : busy ? '正在检查客户端…' : '等待检查客户端' }}</span><span>Made for your two worlds <span class="footer-star">✦</span></span></footer>
    </section>
    <div v-if="settings || help" class="modal-backdrop" @click.self="settings = false; help = false" @keydown.esc="settings = false; help = false">
      <section class="modal" role="dialog" aria-modal="true" :aria-label="settings ? '设置' : '使用帮助'"><div class="modal-title"><div><span class="section-kicker">{{ settings ? 'PREFERENCES' : 'QUICK GUIDE' }}</span><h2>{{ settings ? '设置' : '使用帮助' }} <span class="section-star">✦</span></h2></div><button class="icon-button" aria-label="关闭" @click="settings = false; help = false"><X :size="19"/></button></div>
        <template v-if="settings"><label for="client">客户端路径 <span>可选</span></label><p class="field-hint">默认自动查找官方客户端。若未找到，可填写 Windows 程序或 macOS .app 的完整路径。</p><input id="client" v-model="draftPath" placeholder="留空以自动查找" @keyup.enter="saveSettings"/><div class="modal-actions"><button class="plain-button" @click="settings = false">取消</button><button class="primary-small" @click="saveSettings">保存设置</button></div></template>
        <template v-else><ol class="steps"><li><b>打开原窗口</b><p>像平时一样打开官方客户端，原来的项目和聊天会留在原窗口。</p></li><li><b>打开第二窗口</b><p>回到这里点击“打开第二窗口”，首次使用时在官方登录页面选择另一个账号。</p></li><li><b>核对账号</b><p>分别查看两个窗口显示的账号和聊天列表。若自动选中原账号，请在登录页面选择其他账号。</p></li></ol><p class="help-note">应用不会读取密码，也不会自动关闭你的客户端。macOS 适配仍需实机验证。</p><div class="modal-actions"><button class="primary-small" @click="help = false">知道了</button></div></template>
      </section></div>
  </main>
</template>
