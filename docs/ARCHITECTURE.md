# Project.AE模板智能庫 架構圖

生成時間：2026-07-02 22:37

## 架構總覽

```mermaid
flowchart TD
    A[專案根目錄] --> B[README.md]
    A --> C[docs/ARCHITECTURE.md]
    A --> D[docs/說明書.html]
    A --> T1[logs/]
    A --> L[主要技術/內容]
    L --> L1[React: 1 檔]
    L --> L2[PowerShell: 1 檔]
    A --> N[關鍵入口檔]
    N --> N1[parse_ae_project.jsx]
    N --> N2[scan_ae_templates.ps1]
    N --> N3[template_inventory.json]
    N --> N4[template_inventory.md]
```

## 主要內容

影像、影片或媒體生產流程。目前偵測到主要內容型態：React, PowerShell。

## 子資料夾

- `logs/`

## 技術/檔案型態

- React: 1 檔
- PowerShell: 1 檔

## 邊界與風險

- 此文件只根據本機檔案結構與非敏感檔名推斷，不讀取或揭露金鑰、token、session、cookie、`.env` 等敏感資料。
- 自動圖只描述目前可見結構；若專案有外部服務、雲端帳號或手動流程，需由後續人工驗收補充。
