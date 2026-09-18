import type { ToolContract } from "./tool-contracts.js";
import type { Tool } from "@modelcontextprotocol/server";

type Schema = NonNullable<Tool["inputSchema"]["properties"]>[string];
const number = (minimum: number, maximum: number): Schema => ({ type: "number", minimum, maximum });
const boolean: Schema = { type: "boolean" };
const selectedPhoto: Schema = {
  type: "string", minLength: 1,
  description: "Optional guard: fail if this is not the active photo ID. This does not change selection.",
};
const settings: Schema = {
  type: "object", minProperties: 1, maxProperties: 150,
  propertyNames: { type: "string", minLength: 1, maxLength: 80 },
  additionalProperties: { type: "number" },
  description: "Absolute slider values, case-insensitive. Exposure is an alias for Exposure2012 in catalog writes. Ranges are checked against the active photo; values are not deltas.",
};

function tool(name: string, handler: string, description: string,
  properties: Record<string, Schema> = {}, required: string[] = []): ToolContract {
  return {
    name, luaHandler: `HandlerController.${handler}`, description,
    inputSchema: {
      type: "object", additionalProperties: false,
      properties: { ...properties, photo_id: selectedPhoto },
      ...(required.length ? { required } : {}),
    },
  };
}

export const DEVELOP_TOOL_CONTRACTS: ToolContract[] = [
  tool("lr_ping", "ping", "Check the authenticated Lightroom connection and runtime version."),
  tool("lr_capabilities", "capabilities", "Inspect actual Lightroom runtime APIs, supported sliders and limits, and feature caveats before using version-dependent tools."),
  tool("lr_get_settings", "getSettings", "Read the active photo's current develop settings, controller slider ranges, ID, filename and rating."),
  tool("lr_apply_settings", "applySettings", "Set absolute global develop slider values on the active photo. Preflight all names and ranges, then report values read back from Lightroom. This is not AI Denoise.", { settings }, ["settings"]),
  tool("lr_batch_apply_settings", "batchApplySettings", "Apply absolute global settings to the explicitly selected photos using catalog SDK keys. An empty selection is an error. Reports per-photo failures; ordinary noise sliders are not AI Denoise.", { settings }, ["settings"]),
  tool("lr_auto_tone", "autoTone", "Run Lightroom Auto Tone on the active photo."),
  tool("lr_reset", "reset", "Reset ALL develop adjustments on the active photo. Existing edits will be replaced by defaults."),
  tool("lr_export_preview", "exportPreview", "Render the active photo's current edits as an sRGB JPEG and return MCP image content. Rendering is done by Lightroom, including Nikon NEF decoding. Removes temporary render files.", {
    size: { type: "integer", minimum: 64, maximum: 2048, default: 1500 },
  }),
  tool("lr_crop", "crop", "Crop the active photo in normalized 0..1 coordinates and/or straighten it. Checks the final combined rectangle before writing.", {
    angle: number(-45, 45), CropTop: number(0, 1), CropBottom: number(0, 1),
    CropLeft: number(0, 1), CropRight: number(0, 1),
  }),
  tool("lr_add_mask", "addMask", "Start a mask using Lightroom's SDK. Some types require drawing, sampling or choosing a person/object in Lightroom. Geometry parameters are not supported. Adjustments are applied only to a verified newly selected mask; a pending operation is never reported as completed.", {
    maskType: { type: "string", enum: ["subject", "sky", "background", "objects", "people", "landscape", "luminance", "color", "depth", "gradient", "radialGradient", "brush"] },
    params: { type: "object", additionalProperties: false, description: "Only an empty object is supported; the public mask creation call does not accept geometry." },
    adjustments: settings,
  }, ["maskType"]),
  tool("lr_update_mask", "updateMask", "Set local sliders on the mask currently selected in Lightroom. Fails when the SDK cannot verify a selected mask. Does not create a mask.", { adjustments: settings }, ["adjustments"]),
  tool("lr_lens_blur", "lensBlur", "Control Lens Blur when exposed by this Lightroom runtime. GPU/image support is determined by Lightroom. Errors are reported and accepted requests do not certify completion of background AI processing.", {
    active: { type: "boolean", default: true }, amount: number(0, 100),
    bokeh: { type: "string", enum: ["Circle", "SoapBubble", "Blade", "Ring", "Anamorphic"] },
    catEye: number(0, 100), highlightsBoost: number(0, 100), focalRangeFromSubject: boolean,
  }),
  tool("lr_enhance", "enhance", "Request AI Enhance using Lightroom's runtime API when available. This differs from ordinary noise-reduction sliders. Returns submission status, not a claim that a DNG was created or background processing finished.", {
    denoise: boolean, denoiseAmount: number(1, 100), superRes: boolean, rawDetails: boolean,
  }),
];
