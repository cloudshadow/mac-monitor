// Generated; edit locales instead.
export const languages = [
  {
    "tag": "en",
    "nativeName": "English",
    "englishName": "English",
    "direction": "ltr",
    "aliases": [
      "en-US",
      "en-GB"
    ],
    "status": "published",
    "resources": {
      "apps": "/locales/en/apps.json",
      "auth": "/locales/en/auth.json",
      "common": "/locales/en/common.json",
      "dashboard": "/locales/en/dashboard.json",
      "errors": "/locales/en/errors.json",
      "history": "/locales/en/history.json",
      "native": "/locales/en/native.json",
      "pairing": "/locales/en/pairing.json",
      "settings": "/locales/en/settings.json"
    }
  },
  {
    "tag": "zh-Hans",
    "nativeName": "简体中文",
    "englishName": "Simplified Chinese",
    "direction": "ltr",
    "aliases": [
      "zh-CN",
      "zh-SG",
      "zh"
    ],
    "status": "published",
    "resources": {
      "apps": "/locales/zh-Hans/apps.json",
      "auth": "/locales/zh-Hans/auth.json",
      "common": "/locales/zh-Hans/common.json",
      "dashboard": "/locales/zh-Hans/dashboard.json",
      "errors": "/locales/zh-Hans/errors.json",
      "history": "/locales/zh-Hans/history.json",
      "native": "/locales/zh-Hans/native.json",
      "pairing": "/locales/zh-Hans/pairing.json",
      "settings": "/locales/zh-Hans/settings.json"
    }
  },
  {
    "tag": "zh-Hant",
    "nativeName": "繁體中文",
    "englishName": "Traditional Chinese",
    "direction": "ltr",
    "aliases": [
      "zh-TW",
      "zh-HK",
      "zh-MO"
    ],
    "status": "published",
    "resources": {
      "apps": "/locales/zh-Hant/apps.json",
      "auth": "/locales/zh-Hant/auth.json",
      "common": "/locales/zh-Hant/common.json",
      "dashboard": "/locales/zh-Hant/dashboard.json",
      "errors": "/locales/zh-Hant/errors.json",
      "history": "/locales/zh-Hant/history.json",
      "native": "/locales/zh-Hant/native.json",
      "pairing": "/locales/zh-Hant/pairing.json",
      "settings": "/locales/zh-Hant/settings.json"
    }
  }
] as const;
export type Language = typeof languages[number]['tag'];
