> **Note.** The ESP32 firmware is a not-included Freenove derivative — `firmware/…` paths below are *descriptive*, not files in this repo. This feature is **shipped** (app v1.1.54): the car reboots into pure STA and the app confirms it on the network (status strings `idle | switching:<ssid> | fail:auth | fail:no_ap`).

# WiFi プロビジョニング設計書 (in-app WiFi setup)

> ステータス: **完成・実車E2E成功 (v1.1.50 / reboot-to-STA + 診断 + wait-for-IP)**。設定モード→SoftAP→SET→純STA再起動→NVS credsで接続→再発見をシリアルログで確認。根本原因(AP_STAチャンネル固定)実測CONFIRMED。未プッシュ。単一の正。
> 目的: 車体(ESP32)を **アプリだけで新しいWiFiに接続**できるようにする。引っ越し／別の家／別ルーターで **再フラッシュ不要**に。

---

## 1. 現状 (実コード確認済み・2026-07-xx)

- **アプリ側: WiFiプロビジョニングUI/ロジックはゼロ**（`ios_app/*.swift` に SSID 関連なし）。
- **ファーム側: creds ハードコード**。`firmware/AI_Car_Firmware/wifi_secrets.h` の `WIFI_ROUTER_SSID/PASS` を `AI_Car_Firmware.ino` の `WiFi_Init()` が読み、`WiFi_Setup(0)`＝**STAモードで固定ルーターに接続**。SoftAP名 `"Sunshine"` は定義済みだが起動時は未使用。**NVS保存も WiFi スキャンも無い。**
- 車体は mDNS `robotbrain.local` を広告、コマンド鯖 TCP `:4000`（`#`区切り `CMD_*`）＋映像 `:7000`。アプリ `CarLink` は `carIP`(既定 `robotbrain.local`) に接続。
- **課題**: WiFi を変えるには `wifi_secrets.h` 書換え＋USB再フラッシュが必須＝可搬性が低い。

---

## 2. 要件

**FR**
- FR-P1: アプリから、車体が接続する WiFi の **SSID/パスワードを設定**できる（USB/再フラッシュ不要）。
- FR-P2: SSID は **車体がスキャンした一覧から選択**できる（iOSはWiFiスキャン不可のため車体が供給）。手入力（ステルスSSID）も可。
- FR-P3: 設定した creds は車体の **NVS(不揮発)に保存**され、再起動後も維持。
- FR-P4: 設定後、車体は STA で新WiFiに接続し、**アプリが接続成功を確認**して通常モードに戻る。
- FR-P5: **失敗フォールバック**: creds が無い/接続失敗/一定時間 STA 不通 → 車体は SoftAP プロビジョニングモードに（再入可能・詰まない）。
- FR-P6: アプリは網の渡り（車体AP⇄家WiFi）を **可能な限り自動化**（`NEHotspotConfiguration`）。不可時は手動手順を明示。

**NFR**
- NFR-P1: **2.4GHz のみ**（ESP32 は 5GHz 非対応）＝UIで明示、5GHz SSID は警告。
- NFR-P2: 既存の LAN/Remote/探索の動作を壊さない（プロビジョニングは別モード）。
- NFR-P3: セキュリティ: SoftAP はパスワード付き（近所から勝手に設定されない）。パスは NVS 平文（デバイス標準）＋ローカルAP内送信のみ。ログに出さない。
- NFR-P4: LAN/Remote いずれのアプリモードからも設定導線に入れる。

---

## 3. 重要な制約（正直に・盛らない）

1. **iOSアプリは WiFi をスキャンできない**（近隣SSID一覧の公開APIなし; NEHotspotHelper は MFi 限定）。→ **車体(ESP32 `WiFi.scanNetworks()`)がスキャンして一覧をアプリへ返す**。
2. **スマホは網を2回渡る**: 家WiFi → 車体AP(設定) → 家WiFi(通常)。同一ネットでないと会話不可。`NEHotspotConfigurationManager` で「このAPに繋ぐ」をアプリから発行可（**要エンタイトルメント `com.apple.developer.networking.HotspotConfiguration`**、iOSが確認ダイアログを出す）。家WiFiへの復帰も同APIで（パスをアプリが保持していれば自動、未知なら手動案内）。
3. **`#` デリミタ問題（設計の肝）**: 既存 CMD は `#` 区切り。**WiFiパスワード/SSIDに `#` や区切り文字が入りうる**ため、`CMD_WIFI_SET#ssid#pass` は壊れる。→ **フィールドを base64 エンコード**して送る（`CMD_WIFI_SET#<b64ssid>#<b64pass>`）か、HTTP(下記代替)を使う。**必須対策**。
4. SoftAP 中はスマホにインターネットが無い（Remote/クラウドは使えない＝設定は純ローカル）。
5. mDNS 再発見: STA 復帰後、アプリは `robotbrain.local` で車体を再発見（DHCP IP 変動に強い）。

---

## 4. アーキテクチャ / 状態遷移

### 4.1 車体ファームの状態機械
```
[BOOT]
  └─ NVS に creds 有り? 
       ├─ 有 → STA接続を試行（最大 STA_TRY_MS 例:20s）
       │        ├─ 成功 → [NORMAL] (mDNS広告, :4000/:7000, 既存動作すべて)
       │        └─ 失敗/タイムアウト → [PROVISION]
       └─ 無 → [PROVISION]

[PROVISION]  (SoftAP "RobotBrain-setup" をパス付きで起動; :4000 コマンド鯖は稼働)
  ├─ CMD_WIFI_SCAN        → 近隣SSID一覧(JSON or 区切り)を返す
  ├─ CMD_WIFI_SET#b64ssid#b64pass → NVS保存 → STA接続試行
  │        ├─ 成功 → CMD_WIFI_STATUS が "ok:<ip>" → 数秒後 [NORMAL] へ(SoftAP停止)
  │        └─ 失敗 → CMD_WIFI_STATUS が "fail:<reason>" → PROVISION 継続(再入力可)
  └─ (無操作タイムアウトでも PROVISION 維持=詰まない)
```
- **プロビジョニング中も `:4000` を使う**（新規HTTP鯖を足さず既存作法に載せる）。SoftAP のIPは既定 `192.168.4.1`。
- STA接続の確認は **ESP32側で** `WiFi.status()==WL_CONNECTED` を待ち、成功時に取得IPを `CMD_WIFI_STATUS` で返す。

### 4.2 アプリのフロー
1. ユーザーが設定画面で「車体のWiFiを設定」をタップ（or 車体が `robotbrain.local` で見つからない時に自動で促す）。
2. アプリが `NEHotspotConfiguration` で **車体AP `RobotBrain-setup` に接続**（要エンタイトルメント; iOS確認ダイアログ）。
3. アプリが `192.168.4.1:4000` に接続 → `CMD_WIFI_SCAN` → **SSID一覧を表示**。ユーザーが選択＋パス入力（2.4GHz以外は警告）。
4. アプリが `CMD_WIFI_SET#<b64ssid>#<b64pass>` を送信。
5. アプリが `CMD_WIFI_STATUS` をポーリング（数秒〜STA_TRY_MS）。
   - `ok:<ip>` → 成功。アプリは `NEHotspotConfiguration` で **家WiFiに復帰**（パス既知なら自動、未知なら「手動で家WiFiに戻って」と案内）→ `robotbrain.local` で **mDNS再発見→通常モード** ✅
   - `fail:...` → エラー表示＋SSID/パス再入力（手順3へ）。
6. どの段階でも「キャンセル」で家WiFiへ復帰。

---

## 5. ワイヤプロトコル (新規 CMD, `Freenove_4WD_Car_WiFi.h` に追加)

| CMD | 引数 | 応答 | 用途 |
|---|---|---|---|
| `CMD_WIFI_SCAN` | なし | `CMD_WIFI_SCAN#<b64 of "ssid1\trssi1\tenc1\nssid2\t..">` | 近隣AP一覧（SSIDは非ASCII対応でb64） |
| `CMD_WIFI_SET` | `#<b64ssid>#<b64pass>` | `CMD_WIFI_SET#accepted` | 受領→NVS保存→STA試行開始 |
| `CMD_WIFI_STATUS` | なし | `CMD_WIFI_STATUS#idle\|trying\|ok:<ip>\|fail:<reason>` | STA接続結果のポーリング |
| `CMD_WIFI_FORGET` | なし | `CMD_WIFI_STATUS#idle` | NVSクリア→次回起動でPROVISION（デバッグ/引っ越し用） |

- **base64 必須**（`#`/改行/非ASCII 対策, §3-3）。既存 `Get_Command` の `#` 分割はそのまま使え、値だけ b64 で安全。
- パスワードは **シリアル/デバッグに出さない**（NFR-P3）。

---

## 6. 実装チェックリスト（ファイル → 変更）

**ファーム (`firmware/AI_Car_Firmware/`)**
1. `Freenove_4WD_Car_WiFi.h`: `#define CMD_WIFI_SCAN/SET/STATUS/FORGET`。
2. 新規 `wifi_provision.{h,cpp}`（or 既存 WiFi.cpp 拡張）: `Preferences`(NVS, namespace `"wifi"`) で `ssid`/`pass` 読み書き; `provisionStatus`(idle/trying/ok/fail); `startSoftAP()`（パス付き `RobotBrain-setup`）; `tryConnectSTA(ssid,pass, STA_TRY_MS)`; `scanToB64()`。
3. `AI_Car_Firmware.ino`:
   - `WiFi_Init()`/`setup()`: **NVS creds を優先**（有→STA試行、失敗/無→SoftAPプロビジョニング）。`wifi_secrets.h` は **初回フォールバック既定値**として残す（NVS未設定時のみ使用）＝既存挙動を壊さない。
   - `loop()` のコマンド分岐に `CMD_WIFI_*` を追加（`Get_Command` 後、`CMD_POWER` と同様の返信）。
   - プロビジョニング中も `:4000` accept を回す（SoftAP時も同じ鯖でOK）。STA成功後に mDNS 再広告。
4. `wifi_secrets.h.example`: コメントに「NVS未設定時のみ使う初期値」と明記。

**アプリ (`ios_app/`)**
5. エンタイトルメント: `com.apple.developer.networking.HotspotConfiguration`（`project.yml` の entitlements）。
6. `WiFiSetup`（新規 View, `ConfigView` から遷移 or 未発見時に自動提示）: 状態機（AP接続→スキャン一覧→SSID選択/パス入力→送信→STATUSポーリング→家WiFi復帰→mDNS確認）。5GHz/長さ等の入力バリデーション＋2.4GHz注意書き。
7. `WiFiProvisioner`（新規, `NEHotspotConfigurationManager` ラッパ）: `joinAP("RobotBrain-setup", pass)` / `rejoin(home)` / エラー整形。iOS確認ダイアログ前提の非同期。
8. `CarLink`（or 専用プロビジョニング接続）: `192.168.4.1:4000` への一時接続＋ `CMD_WIFI_SCAN/SET/STATUS` の送受信（base64 エンコード/デコード）。既存の LAN 接続とは分離（プロビジョニングは別コンテキスト）。
9. `Discovery`(mDNS): STA復帰後の `robotbrain.local` 再発見をトリガ。
10. Localizable(ja/en): 設定文言・エラー・「家WiFiに手動で戻って」案内。

---

## 7. 失敗・エッジケース

- **パス間違い / 圏外**: `CMD_WIFI_STATUS#fail` → アプリで再入力。車体は PROVISION 維持（詰まない）。
- **家WiFi自動復帰不可**（アプリがパス未保持）: 「Wi‑Fi設定で家のネットに戻してください」と明示 → 戻ったら mDNS 再発見。
- **5GHz を選んだ**: 事前警告＋接続失敗時に理由表示。
- **SSID/パスの `#`・非ASCII・絵文字**: base64 で回避（§3-3）。
- **SoftAP に複数端末**: 単一接続前提（既存 `:4000` は単一クライアント）。
- **セキュリティ**: SoftAP はパス付き; 送信はローカルAP内のみ; NVS 平文（標準）; パスをログに出さない。
- **既存動作維持**: NVS 未設定時は従来どおり `wifi_secrets.h` の固定値で STA＝現状の挙動を壊さない（段階移行）。

---

## 8. 実車でしか確定できないこと ([[state-limits-plainly]])

- `NEHotspotConfiguration` の実機ダイアログ挙動・自動接続の成否（要 Apple Developer 実機＋エンタイトルメント）。
- SoftAP⇄STA 切替のタイミング/安定性、`STA_TRY_MS` の適正値。
- スキャン一覧の見え方（RSSI/隠しSSID）、2.4GHz限定の実挙動。
- 家WiFi自動復帰がユーザ環境で通るか（パス保持の可否）。
- ネイティブ実装前に、`wifi_secrets.h` フォールバックのままでも回帰しないことの確認。

---

## 9. 未決定（実装前に選ぶ）

- **A. 送信トランスポート**: (推奨) 既存 `:4000` ＋ base64 CMD / vs. SoftAP に小さな HTTP 鯖（ブラウザからも設定できる captive 併用）。※「アプリだけで」を最優先なら CMD、汎用性重視なら HTTP。
- **B. 網の渡り自動化**: `NEHotspotConfiguration` で自動 / vs. 手動案内のみ（エンタイトルメント無しでも成立するが手間）。
- **C. プロビジョニング起動条件**: 「NVS無 or STA失敗で自動 SoftAP」/ vs. 物理ボタン長押しでも入れる。
- **D. SoftAP のSSID名/パス**（既定案: `RobotBrain-setup` / ランダム or 固定）。

推し: **A=CMD(base64)、B=自動、C=自動(STA失敗フォールバック)、D=固定パス付き**。
