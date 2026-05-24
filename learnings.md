# EdgeTX Lua Scripting Learnings

This document tracks the key learnings and quirks of writing EdgeTX Lua telemetry scripts, specifically for monochrome (B&W) surface radios like the Radiomaster MT12.

## 1. Screen Clearing (`lcd.clear()`)
- **Quirk:** `lcd.clear()` IS required at the start of `run()` in EdgeTX telemetry scripts to prevent the underlying OS menu from bleeding through and causing flashing.
- **Symptom:** The `edgetx-dev-kit` VS Code extension throws a custom warning: `⚠️ EdgeTX: lvgl.clear() is not available on non-color displays..`
- **Lesson:** This warning is a pure false positive from the extension. Ignore the warning and leave `lcd.clear()` in your script, otherwise the telemetry menu ("Execute", "View Text", etc.) will bleed through your graphics.

## 2. Telemetry Script Return Values
- **Quirk:** The `run(event)` function in a telemetry script must explicitly return a value (typically `return 0` to indicate a normal exit and request to be called again).
- **Symptom:** If the `run()` function omits a return statement (implicitly returning `nil`), the script will crash every frame. This can cause the underlying OS telemetry menu text to flash or bleed through the script graphics, and generates the error `-E- Script run function returned unexpected value`.
- **Lesson:** Always add `return 0` at the very end of your `run` function.

## 3. Pixel Inversion and Drawing Flags
- **Quirk:** By default, OpenTX/EdgeTX uses the `SOLID` pattern for `lcd.drawLine()`. When a line is drawn over an already dark area using `SOLID`, the pixels are XOR'd (inverted), resulting in a light/empty pixel.
- **Symptom:** Dark limit markers drawn over dark filled rectangles appeared white or "open".
- **Lesson:** To force a dark pixel to stay dark when drawing over an existing dark area, use the `FORCE` pattern constant instead of `SOLID`.

## 4. Text Alignment and `CENTERED`
- **Quirk:** The `CENTERED` flag does not exist or is unsupported on EdgeTX monochrome displays.
- **Symptom:** Attempting to use `SMLSIZE + INVERS + CENTERED` throws an arithmetic error (`attempt to perform arithmetic on a nil value`) because `CENTERED` evaluates to `nil`.
- **Lesson:** To horizontally center text, calculate the width manually using `lcd.getTextWidth(text, size_flag)` and offset the X-coordinate: `x_center - (text_width / 2)`.

## 5. MT12 Surface Radio Input Names
- **Quirk:** Standard aviation source names like `"rud"` (Rudder) and `"thr"` (Throttle) do not reliably map to the physical controls on surface radios like the MT12. The steering wheel and throttle trigger are usually mapped to `"st"` and `"th"`.
- **Quirk:** Physical trims are named `"T1"` through `"T5"`, but the OS might internally refer to them by function (`"trim-st"`, `"TrmST"`, `"TrmR"`, etc.) depending on the firmware configuration.
- **Lesson:** When fetching input values, build an automated fallback to resolve the correct source name dynamically using `getFieldInfo()`:
  ```lua
  local srcSteering = pickSource({ "st", "rud", "ail" }) or "st"
  local srcTrimST = pickSource({ "trim-st", "TrmST", "T1", "TrmR" }) or "T1"
  ```

## 6. Language Server False Positives
- **Quirk:** The `jeffreychix.edgetx-dev-kit` VS Code extension provides stubs that may trigger false positive diagnostics.
- **Symptom:** Errors like `undefined-field` for `lcd.getTextWidth`, `missing-parameter` for `getFlightMode()`, `inject-field`, and `duplicate-doc-field`.
- **Lesson:** Suppress these safely via `.luarc.json` by adding the codes to the `"disable"` array, or use `---@diagnostic disable-next-line: [code]` inline when necessary.
