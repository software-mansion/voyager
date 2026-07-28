# JetBrains Mono (vendored)

Latin variable build of JetBrains Mono with the slashed zero (`zero` OpenType feature) baked into the default cmap.

Fontsource/Google builds strip the `zero` feature, so we vendor the official font with that alternate remapped as default.

## Files

| File | Purpose |
| --- | --- |
| `jetbrains-mono-latin-wght-normal.woff2` | Variable latin subset (weights 100–800) |
| `OFL.txt` | SIL Open Font License 1.1 |

## Upstream

- Source: [JetBrains/JetBrainsMono](https://github.com/JetBrains/JetBrainsMono)
- Version: **2.304** (from the font name table)
- Input file: `fonts/variable/JetBrainsMono[wght].ttf` from the release

## Regenerating

Requires Python packages:

```sh
pip install 'fonttools[woff]' opentype-feature-freezer
```

(`pyftfeatfreeze` comes from [opentype-feature-freezer](https://github.com/twardoch/fonttools-opentype-feature-freezer).)

```sh
# 1. Freeze the slashed-zero alternate into the default cmap
pyftfeatfreeze -f zero JetBrainsMono\[wght\].ttf JetBrainsMono\[wght\]-zero.ttf

# 2. Latin subset + compress to woff2
pyftsubset JetBrainsMono\[wght\]-zero.ttf \
  --unicodes="U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD" \
  --layout-features='*' \
  --flavor=woff2 \
  --output-file=jetbrains-mono-latin-wght-normal.woff2
```

Copy the resulting `jetbrains-mono-latin-wght-normal.woff2` into this directory. `mix assets.build` copies it to `priv/static/fonts/`.
