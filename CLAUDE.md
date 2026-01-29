# Claude Token Battery

Claude Code の 5時間 rate limit を電池風に表示する Mac ステータスバーアプリ。

## 概要

- トークンの残り使用可能量を % 表示
- 残量の割合により緑・黄色・赤の色分け
- ステータスバーアイコンクリックでリセット時間を表示
- プランを自動判定（Max5, Max20, Pro）

## 技術スタック

- **言語**: Swift 5.9+
- **フレームワーク**: SwiftUI, AppKit
- **プラットフォーム**: macOS 13+
- **ビルド**: Swift Package Manager

## プロジェクト構造

```
.
├── Sources/
│   ├── ClaudeTokenBatteryApp.swift  # アプリエントリーポイント
│   ├── Models.swift                  # データモデル（RateLimitInfo, BatteryColor等）
│   ├── RateLimitService.swift        # トークン使用量計算ロジック
│   └── StatusBarController.swift     # ステータスバーUI制御
├── Resources/
│   └── Info.plist                    # アプリ設定（LSUIElement等）
├── scripts/
│   └── build-release.sh              # リリースビルドスクリプト
└── Package.swift
```

## ビルド・実行

### 開発用（デバッグビルド）

```bash
swift build
.build/debug/ClaudeTokenBattery
```

### リリースビルド

```bash
# ビルドスクリプト実行
./scripts/build-release.sh

# アプリバンドルが生成される
# .build/release/ClaudeTokenBattery.app
```

### インストール

```bash
# Applicationsフォルダにコピー
cp -r .build/release/ClaudeTokenBattery.app /Applications/

# または直接実行
open .build/release/ClaudeTokenBattery.app
```

### ログイン時に自動起動

システム環境設定 → 一般 → ログイン項目 → ClaudeTokenBattery.app を追加

## トークン使用量の計算方法

### データソース

`~/.claude/projects/` 配下の JSONL ファイルからトークン使用量を集計。

### カウント対象

- `input_tokens`: ✓ カウント
- `output_tokens`: ✓ カウント
- `cache_creation_input_tokens`: ✗ カウントしない
- `cache_read_input_tokens`: ✗ カウントしない

### プラン別上限（2026年1月時点の実測値）

| プラン | 上限 | rateLimitTier |
|--------|------|---------------|
| Max20 | 150,000 | `default_claude_max_20x` |
| Max5 | 60,000 | `default_claude_max_5x` |
| Pro | 30,000 | `pro` |

※ 公式値（88K等）より低い実測値を使用。2026年1月以降、rate limitが厳しくなったとの報告多数。

### プラン判定

`~/.claude/.credentials.json` の `rateLimitTier` フィールドから自動判定。

## 既知の制限

1. **API未対応**: `https://api.anthropic.com/api/oauth/usage` エンドポイントは現時点でOAuth認証未サポート
2. **推定値**: ローカルJSONLファイルからの集計のため、Claude Code公式表示と若干の誤差あり
3. **5時間ウィンドウ**: 直近5時間のファイル更新日時でフィルタリング

## デバッグ

デバッグログは `/tmp/claude-battery-debug.log` に出力される。

```bash
# ログ確認
tail -f /tmp/claude-battery-debug.log
```

## 参考情報

- [Claude Code Token Limits - Faros AI](https://www.faros.ai/blog/claude-code-token-limits)
- [ccusage - GitHub](https://github.com/ryoppippi/ccusage)
- [Claude-Code-Usage-Monitor - GitHub](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)
