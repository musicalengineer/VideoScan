# Family Photograph Restoration Report

Date: 2026-08-23  
Primary source folder: `/Users/rickb/dev/VideoScan/tests/fixtures/photos/`  
Additional source: Apple Photos rendered image supplied separately

The originals were not modified. Accepted results were saved as PNG files in the source folder's `Restored` subfolder and mirrored with this report. These are AI-assisted interpretive restorations; the original files remain the archival authority.

## Restored

| Source | Source dimensions | Confidence | Notes |
|---|---:|---|---|
| `ChristopherOConnor.jpeg` | 809 x 919 | High | Mild noise and tonal cleanup; glasses, clothing, pose, and setting retained. |
| `EdithBowser.jpeg` | 2905 x 3051 | High | Five-person sepia group retained; fading and surface texture reduced. |
| `EllenOConnor.jpeg` | 870 x 1201 | High | Facial, clothing, hat/veil, corsage, and table-setting detail retained. |
| `Fred Lamb.jpeg` | 457 x 729 | Moderate | Strong cleanup from a smaller source; pose, pipe, clothing, sporting firearm, and landscape retained. |
| `Hallie-May-circa.1900.jpeg` | 1872 x 2893 | Moderate | Heavy grain reduced and oval presentation retained; fine facial and hair detail is necessarily interpretive. |
| `HarrietMerronWaters.jpeg` | 2031 x 2297 | High–moderate | Portrait and caption restored. Caption wording retained exactly. |
| `Mary OConnor Latta.tif` | 391 x 523 | Moderate | Two-person portrait restored from a small source; faces were visible, but fine texture is interpretive. |
| `MurielLambBreen.jpeg` | 1012 x 1265 | High | Profile, hairstyle, soft-focus character, crop, and lighting retained. |
| `WilliamLoveLatta.jpeg` | 2853 x 3836 | High–moderate | Photographed-print texture and glare reduced; facial features and formal clothing retained. |
| `5285A146-59C5-485F-8EC5-AEA3A9E748A5_1_201_a.jpeg` | 407 x 606 | Moderate | Full-length oval portrait restored; face, moustache, suit, stance, hands, railing, and painted backdrop retained. Fine detail is necessarily interpretive. |

## Skipped

| Source | Source dimensions | Reason |
|---|---:|---|
| `E.EvelynDamonBowser.jpeg` | 1894 x 3012 | Severe optical blur; pixel count is high, but reliable facial detail is absent. |
| `GeorgeBreen.jpg` | 132 x 298 | Subject and face are too small for trustworthy identity preservation. |
| `Muriel's Mom?.jpeg` | 188 x 266 | Three faces are too small; restoration would substantially invent identities. |
| `Pa in India (pict)_1.jpg` | 240 x 173 | Complex group scene with extremely small faces and objects; reconstruction would be speculative. |

## Other files

- `DavidThomasMcGill.png` was already the completed reference restoration and was not regenerated.
- `BreenFamilyCrest.png` is artwork rather than a photograph and was not processed.
- The `Donna` subfolder was outside this top-level batch and was not inspected.

## Restoration method and prompt policy

The built-in image editing tool was used once per accepted photograph. Each prompt followed this policy, with subject-specific invariants added for faces, clothing, props, captions, and composition:

> Conservatively restore this historical family photograph. Remove dust, scratches, scan noise, paper texture, stains, and uneven fading; gently improve tonal range and natural photographic clarity. Keep every pictured person faithful to the source, including facial proportions and asymmetry, age, expression, gaze, hair, clothing, pose, hand placement, crop, background, lighting, and visible objects. Preserve the original monochrome or sepia character and modest natural grain. Do not beautify, modernize, invent unavailable detail, add or remove people or objects, colorize, add text, borders, or watermarks.

For photographs containing captions, the exact original text was included verbatim and required to remain unchanged.
