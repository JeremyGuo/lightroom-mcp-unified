import { describe, it, expect, jest } from '@jest/globals';
import { createCallToolHandler } from '../src/tool-handler.js';
import { validateToolArgs } from '../src/validate-args.js';
import { previewImage } from '../src/preview.js';
import { firstText } from './helpers/result.js';
import { DEVELOP_TOOL_CONTRACTS } from '../src/develop-tool-contracts.js';

describe('unified develop surface', () => {
  it('retains all 12 develop tool names and adds capability inspection', () => {
    expect(DEVELOP_TOOL_CONTRACTS.map(t => t.name).sort()).toEqual([
      'lr_add_mask', 'lr_apply_settings', 'lr_auto_tone', 'lr_batch_apply_settings',
      'lr_capabilities', 'lr_crop', 'lr_enhance', 'lr_export_preview', 'lr_get_settings',
      'lr_lens_blur', 'lr_ping', 'lr_reset', 'lr_update_mask',
    ]);
  });

  it.each([
    ['lr_export_preview', { size: 0 }],
    ['lr_export_preview', { size: 4096 }],
    ['lr_apply_settings', { settings: {} }],
    ['lr_apply_settings', { settings: { Exposure: '1' } }],
    ['lr_crop', { CropTop: -0.01 }],
    ['lr_crop', { angle: 50 }],
    ['lr_add_mask', { maskType: 'magic' }],
    ['lr_add_mask', { maskType: 'gradient', params: { angle: 45 } }],
    ['lr_enhance', { denoiseAmount: 0 }],
    ['lr_enhance', { denoiseAmount: 101 }],
    ['lr_enhance', { wait: 'true' }],
    ['lr_enhance', { timeout_seconds: 0 }],
    ['lr_enhance', { timeout_seconds: 241 }],
    ['lr_enhance', { timeout_seconds: 1.5 }],
    ['lr_lens_blur', { amount: 101 }],
    ['lr_update_mask', { adjustments: { Exposure: true } }],
  ])('rejects unsafe or unsupported arguments for %s', (name, args) => {
    expect(validateToolArgs(name as string, args)).not.toBeNull();
  });

  it('returns an MCP error for partial failures instead of false success', async () => {
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: {
      call: async () => ({ id: '1', result: { success: false, applied: 1, failures: ['bad photo'] } }),
    } });
    const result = await handler('lr_batch_apply_settings', { settings: { Exposure: 1 } });
    expect(result.isError).toBe(true);
    expect(JSON.parse(firstText(result))).toMatchObject({ applied: 1 });
  });

  it('rejects internal/raw-TCP actions from the MCP tool surface', async () => {
    const call = jest.fn(async () => ({ id: '1' }));
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: { call } });
    expect((await handler('set_selection', {})).isError).toBe(true);
    expect(call).not.toHaveBeenCalled();
  });

  it('returns JPEG image content without repeating base64 in text', async () => {
    const data = Buffer.from([255, 216, 255, 224, 0, 2, 255, 217]).toString('base64');
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: {
      call: async () => ({ id: '1', result: { success: true, image_base64: data, mime_type: 'image/jpeg', photo_id: '42' } }),
    } });
    const result = await handler('lr_export_preview', {});
    expect(result.isError).toBeUndefined();
    expect(result.content[1]).toEqual({ type: 'image', mimeType: 'image/jpeg', data });
    expect(firstText(result)).not.toContain(data);
    expect(JSON.parse(firstText(result))).toMatchObject({ photo_id: '42' });
  });

  it.each([
    { path: '/private/photo.jpg' },
    { mime_type: 'image/jpeg', image_base64: 'garbage!' },
    { mime_type: 'image/jpeg', image_base64: Buffer.from('not a JPEG').toString('base64') },
    { mime_type: 'image/jpeg', image_base64: Buffer.from([255, 216, 255, 224]).toString('base64') },
    { mime_type: 'image/png', image_base64: '/9j/2Q==' },
  ])('rejects untrusted preview payloads', (response) => {
    expect(() => previewImage(response)).toThrow();
  });
});
