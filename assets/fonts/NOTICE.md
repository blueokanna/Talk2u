# Bundled fonts

All four files in this directory are registered in `pubspec.yaml` and used by
`lib/src/theme/app_theme.dart`:

| File | Family | Weight | Copyright |
| --- | --- | --- | --- |
| `GoogleSans-Variable.ttf` | Google Sans | 400 (variable) | Copyright 2025 The Google Sans Project Authors ([googlefonts/googlesans](https://github.com/googlefonts/googlesans)) |
| `HarmonyOS_SansSC_Regular.ttf` | HarmonyOS Sans SC | 400 | Copyright 2021-2025 Huawei Device Co., Ltd. |
| `HarmonyOS_SansSC_Medium.ttf` | HarmonyOS Sans SC | 500 | Copyright 2021-2025 Huawei Device Co., Ltd. |
| `HarmonyOS_SansSC_Bold.ttf` | HarmonyOS Sans SC | 700 | Copyright 2021-2025 Huawei Device Co., Ltd. |

## Licenses

`GoogleSans-Variable.ttf` declares the SIL Open Font License 1.1 in its own name
table (`license` id 13: "This Font Software is licensed under the SIL Open Font
License, Version 1.1", `license URL` id 14: <https://openfontlicense.org>), so
redistributing it with the application is allowed under that license.

The three HarmonyOS Sans SC files carry Huawei's copyright with no license
string embedded. Before publishing a build outside this repository, confirm the
redistribution terms that Huawei ships with HarmonyOS Sans, or replace the files
with a font whose license is unambiguous (the theme lists `Noto Sans CJK SC` in
its fallback chain for that case).

## How they are used

`AppTheme.build` applies `fontFamily: 'Google Sans'` with
`fontFamilyFallback: ['HarmonyOS Sans SC', 'Noto Sans CJK SC', 'Noto Sans SC',
'Noto Sans', 'sans-serif']`. Latin text and symbols therefore use Google Sans,
CJK text falls through to HarmonyOS Sans SC, and a device or build without the
bundled files still renders through the system fallback chain.
