export type Status = { platform: string; version: string; default: number; secondary: number; unknown: number; message: string };
export function stateLabel(count: number): string { return count === 0 ? '未运行' : count === 1 ? '运行中' : `${count} 个进程`; }
export function resultText(s: Status): string { return s.unknown > 0 ? `发现 ${s.unknown} 个未识别的客户端进程，请检查后再启动。` : s.message; }
