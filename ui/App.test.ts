// @vitest-environment jsdom
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest';
import { mount, flushPromises } from '@vue/test-utils';
import App from './App.vue';
const invoke = vi.hoisted(() => vi.fn());
vi.mock('@tauri-apps/api/core', () => ({ invoke }));
const base = { platform:'Windows', version:'1.0', default:1, secondary:0, unknown:0, message:'已就绪' };
describe('主界面', () => {
 beforeEach(() => { localStorage.clear(); Object.defineProperty(window, '__TAURI_INTERNALS__', { configurable:true, value:{} }); invoke.mockReset(); invoke.mockResolvedValue(base); });
 afterEach(() => { vi.restoreAllMocks(); });
 it('展示窗口状态并启动第二窗口', async () => {
  const wrapper=mount(App); await flushPromises(); expect(wrapper.text()).toContain('原账号窗口'); expect(wrapper.text()).toContain('运行中');
  const launch=wrapper.findAll('button').find(b => b.text().includes('打开第二窗口'))!;
  invoke.mockResolvedValueOnce({...base,secondary:1,message:'第二窗口已启动'}); await launch.trigger('click'); await flushPromises();
  expect(invoke).toHaveBeenCalledWith('launch_secondary',{clientPath:null}); expect(wrapper.text()).toContain('第二窗口已启动'); wrapper.unmount();
 });
 it('未识别进程时阻止启动', async () => {
  invoke.mockResolvedValueOnce({...base,unknown:1}); const wrapper=mount(App); await flushPromises();
  const launch=wrapper.findAll('button').find(b => b.text().includes('打开第二窗口'))!;
  expect(launch.attributes('disabled')).toBeDefined(); wrapper.unmount();
 });
 it('保存自定义客户端路径后重新检查', async () => {
  const wrapper=mount(App); await flushPromises(); await wrapper.get('button[aria-label="打开设置"]').trigger('click');
  await wrapper.get('input').setValue('C:\\Example\\Codex.exe'); await wrapper.findAll('button').find(b => b.text()==='保存设置')!.trigger('click'); await flushPromises();
  expect(invoke).toHaveBeenLastCalledWith('check_status',{clientPath:'C:\\Example\\Codex.exe'}); wrapper.unmount();
 });
});
