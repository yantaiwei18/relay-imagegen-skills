---
name: relay-imagegen
description: Generate and edit raster images through a user-configured OpenAI-compatible image API relay, with configurable generation and edit URLs, model, authentication header and scheme, extra headers, compatibility profiles, conversation attachments, iterative edits, multiple references, masks, variants, streaming partials, retries, validation, and non-destructive saves. Use whenever the user asks Codex to create, generate, render, transform, restyle, or edit bitmap visuals through their configured relay. Prefer this skill over provider-specific or built-in image generation unless the user explicitly requests another provider.
---

# Relay Image Generation

Use `scripts/invoke-relay-imagegen.ps1` for image generation and editing through
the configured relay. Never expose credentials in prompts, logs, diagnostics,
output files, or conversation text.

This skill targets relays compatible with the OpenAI Images API. Relays with a
different payload or response schema require a provider-specific adapter.

## Workflow

1. Decide whether the request is text-to-image, reference-guided generation, or
   an edit that must preserve an existing image.
2. Resolve and inspect every attached or mentioned image. Label each as edit
   target, subject reference, style reference, composition reference, or insert.
3. Shape a concise production prompt. Quote exact in-image text verbatim and
   state edit invariants explicitly.
4. Invoke the script directly in the current PowerShell process with a splatted
   hashtable. Never wrap multi-reference calls in `powershell.exe -File`.
5. Inspect all final outputs, show them inline, and report paths and the final
   prompt.
6. For follow-up edits, use the latest output from the current task as the first
   reference and repeat all preservation constraints. Never borrow state from a
   different task.

## Invoke

```powershell
$params = @{
  Prompt = $prompt
  ReferenceImagePath = @(
    "C:\absolute\subject.png"
    "C:\absolute\style.jpg"
  )
  OutputPath = "C:\absolute\outputs\result.jpg"
  Quality = "medium"
}

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$scriptPath = Join-Path $codexHome "skills\relay-imagegen\scripts\invoke-relay-imagegen.ps1"
& $scriptPath @params
```

Omit `ReferenceImagePath` for pure text-to-image. References automatically use
the configured edits endpoint and emit one multipart `image[]` field per file.

## Prompt Shape

Use only relevant fields:

```text
Use case: <photo, product, UI, illustration, marketing, edit, compositing>
Primary request: <user request>
Input images: <Image 1 role; Image 2 role; ...>
Subject: <subject and identity constraints>
Scene/backdrop: <environment>
Style/medium: <photo, illustration, 3D, etc.>
Composition/framing: <framing and placement>
Lighting/mood: <lighting and mood>
Text (verbatim): "<exact text>"
Constraints: <must preserve and must include>
Avoid: <artifacts, unwanted objects, watermark>
```

## References And Masks

- Put every ordinary image in the `ReferenceImagePath` array.
- Preserve order and describe each image by index in the prompt.
- Never pass a reference image as `MaskPath`.
- Add `MaskPath` only for an explicitly supplied alpha-channel PNG mask. The
  mask and first reference must be PNG files with matching dimensions.
- Do not send `input_fidelity` to models that reject it. GPT Image 2 processes
  image inputs at high fidelity automatically.

## Relay Compatibility

Read `RELAY_IMAGE_COMPATIBILITY_PROFILE`:

- `full`: send output format, compression, count, streaming, and partial-image
  controls. Use for relays with current GPT Image API compatibility.
- `standard`: send model, prompt, size, quality, output format, and count; omit
  streaming and compression extensions.
- `minimal`: send only model and prompt, plus image or mask files for edits.
  Use when a relay rejects optional parameters.

Authentication is configurable. Standard OpenAI-style relays use header
`Authorization` with scheme `Bearer`. A relay using `x-api-key: KEY` should set
header `x-api-key` and scheme `none`. Additional static headers may be supplied
as a JSON object.

## Quality, Size, And Variants

- Use `low` for drafts and `medium`, `high`, or `auto` for final work.
- Use `1024x1024` for quick square drafts.
- Use landscape, portrait, 2K, or 4K dimensions only when supported by the
  configured model and relay.
- Set `NumberOfImages` for variants of one prompt. Use separate calls and
  prompts for distinct assets.
- The script validates GPT Image 2 dimensions but leaves other model sizes to
  the relay.

## Output And Failures

- Save final images in the task's user-facing output directory.
- Do not overwrite by default; use `Overwrite` only when explicitly requested.
- Read all final paths from `paths`; `path` remains the first result.
- Use `SavePartialImages` only when intermediate stream files are useful.
- Inspect outputs before presenting them.
- Retry transient network, rate-limit, and server failures automatically.
- If a relay rejects optional fields, retry with `standard`, then `minimal`.
- Report sanitized diagnostics paths without exposing credentials.

## Configuration

- `RELAY_IMAGE_PROVIDER_NAME`: human-readable relay name.
- `RELAY_IMAGE_GENERATIONS_URL`: required full generation endpoint.
- `RELAY_IMAGE_EDITS_URL`: edit endpoint; required for references and masks.
- `RELAY_IMAGE_MODEL`: required model identifier.
- `RELAY_IMAGE_API_KEY`: required credential.
- `RELAY_IMAGE_AUTH_HEADER`: defaults to `Authorization`.
- `RELAY_IMAGE_AUTH_SCHEME`: defaults to `Bearer`; use `none` for no prefix.
- `RELAY_IMAGE_EXTRA_HEADERS_JSON`: optional JSON object of extra headers.
- `RELAY_IMAGE_COMPATIBILITY_PROFILE`: `full`, `standard`, or `minimal`.

Do not fall back to `OPENAI_API_KEY` or provider-specific environment variables.
