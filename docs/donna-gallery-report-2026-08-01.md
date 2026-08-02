# Donna reference-gallery report card (G1)

Gallery: `tests/fixtures/photos/Donna` — 60 files, 60 with a resolved subject face.
Models: buffalo_l (SCRFD-10G + ArcFace-w600k + genderage), providers requested CoreML→CPU; prepare 12.2s, total detect+embed 2.9s (0.05s/photo).

## Per era

| era | photos | subject faces | votable (≥60px) | record-only (25–59px) | intra-era mean cos | sex maj | age range |
|---|---|---|---|---|---|---|---|
| Donna_2000s | 10 | 10 | 10 | 0 | 0.649 | F 10/10F | 34–73 |
| Donna_2010s | 6 | 6 | 6 | 0 | 0.732 | F 6/6F | 57–74 |
| Donna_2020s | 13 | 13 | 13 | 0 | 0.699 | F 12/13F | 47–69 |
| Donna_70s | 8 | 8 | 6 | 2 | 0.524 | F 6/6F | 42–70 |
| Donna_80s | 12 | 12 | 12 | 0 | 0.624 | F 12/12F | 28–62 |
| Donna_90s | 11 | 11 | 11 | 0 | 0.633 | F 10/11F | 32–67 |

## Cross-era centroid cosine matrix

| | Donna_2000s | Donna_2010s | Donna_2020s | Donna_70s | Donna_80s | Donna_90s |
|---|---|---|---|---|---|---|
| Donna_2000s | 1.000 | 0.935 | 0.863 | 0.791 | 0.878 | 0.909 |
| Donna_2010s | 0.935 | 1.000 | 0.890 | 0.770 | 0.837 | 0.864 |
| Donna_2020s | 0.863 | 0.890 | 1.000 | 0.667 | 0.732 | 0.773 |
| Donna_70s | 0.791 | 0.770 | 0.667 | 1.000 | 0.872 | 0.819 |
| Donna_80s | 0.878 | 0.837 | 0.732 | 0.872 | 1.000 | 0.947 |
| Donna_90s | 0.909 | 0.864 | 0.773 | 0.819 | 0.947 | 1.000 |

## Flagged for a human look

| file | why | faces | px | det | sex/age | peer cos |
|---|---|---|---|---|---|---|
| `Donna_2020s/Donna_backyard.jpeg` | attribute model says male — check crop choice | 1 | 301 | 0.88 | M/58 | 0.670 |
| `Donna_70s/Donna-2.jpg` | face below voting tier (54px) | 1 | 54 | 0.84 | F/31 | nan |
| `Donna_70s/Donna-5.jpg` | face below voting tier (52px) | 1 | 52 | 0.72 | F/24 | nan |
| `Donna_90s/Donna-7.jpg` | attribute model says male — check crop choice | 1 | 230 | 0.90 | M/57 | 0.665 |

## Verdict inputs

- Clean votable references: **56** across 6 eras.
- Flagged: 4; unusable: 0.
- No embeddings were persisted (cycle-2 sensitive-data rule).
