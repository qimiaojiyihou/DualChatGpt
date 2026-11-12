import { describe, expect, it } from 'vitest';
import { resultText, stateLabel } from './model';
describe('状态展示', () => { it('区分未运行、运行和重复进程', () => { expect([0,1,2].map(stateLabel)).toEqual(['未运行','运行中','2 个进程']); }); it('优先显示未识别进程', () => { expect(resultText({platform:'Windows',version:'1',default:1,secondary:0,unknown:1,message:'ok'})).toContain('未识别'); }); });
