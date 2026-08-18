import AppKit
import CoreGraphics
import Darwin

// ============================================================
//  たてモニ（内部の本名: くるりんパッ）  メニューバー版  v4.6
//  v4.5 → v4.6: 2026-08-18 公開バージョン表示（APP_VERSION）を
//    v1.0 → v1.1 に上げた。【A】【H】【B】【C】【D】の修正と
//    universal（Intel+Apple Silicon）対応をまとめて反映した番号。
//    ★親分の指摘: 「さんざん修正したのに表示が1.0のままでは、
//    使う人にはバージョンが変わったことが分からない」。その通りで、
//    以後 ユーザーに見える変更（不具合修正・機能追加）をしたら、
//    その都度 APP_VERSION も必ず上げる。★
//  v4.4 → v4.5: 使い方の窓の末尾に「他の拡張ディスプレイアプリと
//    一緒に使うと正しく表示されないことがある」旨の注意書きを追加。
//    2026-08-18。原因の切り分け（DisplayLink台数・USB分岐との関係）は
//    実機で確認したが、環境ごとに条件が違い過ぎるため、これ以上の
//    自動対応は追わず、使い方の説明で案内する方針にした（親分の判断）。
//  v4.3: 張り付き対策の「命綱」を追加（中身が固まったら問答無用で止める）
//  2026-08-13
//
//  役割:
//   このファイルは「皮」だけ。画面を作る仕事は一切していない。
//   実際に縦の画面を作るのは kururin_pa_daemon（v3.1・実機で成功済み）。
//   このアプリは デーモンを 起動する / 止める / 引数を渡す だけ。
//
//  なぜ2本に分けたか:
//   2026-08-13 02:11 に実機で成功したコードを 1文字も書き換えない ため。
//   動いているものを触らない。皮が壊れても中身は無事。
//
//  デーモンに渡す引数:
//   run <cw|ccw> <秒数> <right|left|up|down>
// ============================================================

// ★公開バージョンは 1.0 から始めた（親分の指示 2026-08-13）。
//   ファイル冒頭コメントの v4.6 / v3.8 は くろの作業履歴の番号で、
//   こことは別物。ユーザーに見せる番号は これ一つだけ。
// ★2026-08-18: 【A】【H】【B】【C】【D】の修正とuniversal対応を
//   まとめて反映し、v1.0 → v1.1 に上げた。ユーザーに見える変更を
//   したら、その都度ここを必ず上げること（1回上げて終わりにしない）。
let APP_VERSION = "v1.1"
let MENU_FONT_SIZE: CGFloat = 15.0     // 老眼配慮。小さくしないこと。

// ===== 設定の保存先（UserDefaults） =====
let store = UserDefaults.standard
enum SettingKey {
    static let iriguchi   = "iriguchi"     // right / left / up / down
    static let byou       = "byou"         // 300 / 1800 / 0
    static let guideShown = "guideShown"   // 使い方を1回でも出したか
    static let askedOS    = "askedScreenCaptureOnce"  // ★v4.3★ macOSの許可の窓を1回出したか
}

// ===== 向きの種類 =====
//  yoko … アプリを通さない。素のSidecarに戻す。
//  cw   … 時計回りに倒す  ＝ ホームボタンが 上  ★実機で確認 2026-08-13★
//  ccw  … 反時計回りに倒す ＝ ホームボタンが 下  ★実機で確認 2026-08-13★
//  （v4.2 まではこの対応が逆に書いてあった。理屈ではなく実物が正しい）
let MUKI_YOKO = "yoko"
let MUKI_CW   = "cw"
let MUKI_CCW  = "ccw"


// ============================================================
//  本体
// ============================================================

final class Controller: NSObject, NSApplicationDelegate {

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var daemon: Process?

    // ★v4.3 命綱★
    //  中身（デーモン）は 1秒ごとに /tmp/kururin_pa.heartbeat を書き替える。
    //  それが 6秒 止まったら「固まった」と判断して 問答無用で殺す。
    //  プロセスが死ねば 黒い窓も一緒に消えるので、
    //  親分が操作不能になったままにはならない。
    let heartbeatPath = "/tmp/kururin_pa.heartbeat"
    var heartbeatTimer: Timer?
    var daemonStartedAt = Date.distantPast
    var nowMuki: String = MUKI_YOKO     // 今の状態。起動直後は必ず「横」。
    var guideWindow: NSWindow?

    // ---- 設定の読み書き ----
    var iriguchi: String {
        //  ★初期値は "left"（＝ iPadの 左 から入る）。親分の指定 2026-08-13
        get { store.string(forKey: SettingKey.iriguchi) ?? "left" }
        set { store.set(newValue, forKey: SettingKey.iriguchi) }
    }
    //  「動く時間」は メニューから外した（2026-08-13 親分の指摘）。
    //  止めたいときは メニューで「横」を選ぶか アプリを終了すればいい。
    //  時間で勝手に消えるほうが かえって分かりにくかった。
    //  0 = 止めるまで動き続ける。
    let byou = 0

    // ---- デーモンの置き場所 ----
    //  .app の中でも、裸のバイナリでも、同じ場所を見る。
    var daemonURL: URL {
        let exe = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("kururin_pa_daemon")
    }

    // ---- ログの置き場所（デーモンと同じ計算） ----
    var logURL: URL {
        var dir = daemonURL.deletingLastPathComponent()
        if dir.path.hasSuffix("/Contents/MacOS") {
            dir = dir.deletingLastPathComponent()
                     .deletingLastPathComponent()
                     .deletingLastPathComponent()
        }
        return dir.appendingPathComponent("たてモニ動作ログ.txt")
    }


    // ========================================================
    //  起動
    // ========================================================

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // Dockにアイコンを出さない

        // 前回アプリが落ちたときの居残りデーモンを片付ける
        killStrayDaemons()

        setupStatusIcon()
        refresh()

        // ★親分の選択：起動しても画面はいじらない。使い方を1回出すだけ。
        if !store.bool(forKey: SettingKey.guideShown) {
            store.set(true, forKey: SettingKey.guideShown)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showGuide(nil) }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        stopDaemon()
    }

    func killStrayDaemons() {
        //  ★間違い①の修正★
        //  run() が失敗したのに waitUntilExit() を呼ぶと、
        //  Foundation が「起動していない」と例外を投げてアプリが落ちる。
        //  起動できたときだけ待つ。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "kururin_pa_daemon"]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            // pkill が無くても致命傷ではない。黙って進む。
        }
    }


    // ========================================================
    //  メニューを組み立て直す（状態が変わるたび全部作り直す）
    // ========================================================

    /// メニューバーに出す絵（v4.3・親分が選んだ「案E」）
    ///  横の薄い枠 ＋ 縦の濃い枠 ＝「横から 縦へ」
    ///
    ///  ★AppIcon.icns は使わない★
    ///   1024ピクセルの絵を18ドットに縮めると つぶれる。
    ///   メニューバー用は その場で線を引いて描く。
    ///
    ///  ★template（テンプレート）指定にしている★
    ///   こうすると macOS が バーの明暗に合わせて
    ///   暗いバーでは白、明るいバーでは黒に 自動で描き分ける。
    ///   だから「白いアイコン」を用意する必要がない。
    ///   薄い/濃い の差は 透明度（アルファ）で表す。
    ///
    ///  ※Dock や Finder に出る アプリのアイコンは
    ///    今までどおり AppIcon.icns（親分が作ったもの）。ここでは触らない。
    func setupStatusIcon() {
        guard let button = statusItem.button else { return }
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            // 横の枠（薄い）
            NSColor.black.withAlphaComponent(0.38).setStroke()
            let yoko = NSBezierPath(roundedRect: NSRect(x: 1.4, y: 4.3, width: 15.2, height: 9.4),
                                    xRadius: 2.0, yRadius: 2.0)
            yoko.lineWidth = 1.3
            yoko.stroke()
            // 縦の枠（濃い）
            NSColor.black.setStroke()
            let tate = NSBezierPath(roundedRect: NSRect(x: 4.4, y: 1.3, width: 9.2, height: 15.4),
                                    xRadius: 2.0, yRadius: 2.0)
            tate.lineWidth = 1.7
            tate.stroke()
            return true
        }
        img.isTemplate = true
        button.image = img
        button.imagePosition = .imageOnly
        button.title = ""
    }

    func refresh() {
        if let button = statusItem.button {
            if button.image != nil {
                // 動いているときだけ はっきり見える。止まっているときは薄い。
                button.appearsDisabled = (nowMuki == MUKI_YOKO)
            } else {
                button.title = (nowMuki == MUKI_YOKO) ? "たて" : "たて▶"
            }
        }
        statusItem.button?.toolTip =
            (nowMuki == MUKI_YOKO) ? "たてモニ：停止中（素のSidecar）"
                                   : "たてモニ：iPadに縦画面を出しています"

        let menu = NSMenu()
        menu.autoenablesItems = false

        // ★v4.3★ 許可が無いときだけ 出る行。押すと案内窓を開く。
        //  ふだんは出ない。だから邪魔にならない。
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(plain("画面収録の許可がありません（押すと案内）",
                               #selector(showPermissionGuide)))
            menu.addItem(.separator())
        }

        // ★v4.3: 「終了」を一番上に置いた（親分の指示 2026-08-13）
        menu.addItem(plain("たてモニを終了", #selector(quitApp)))
        menu.addItem(.separator())

        // ★v4.2: アプリ名とバージョンの行は消した（親分の指示 2026-08-13）
        // ★v4.2: 並び順は 横 → 上 → 下（親分の指示）
        menu.addItem(radio("横（そのまま）",
                           on: nowMuki == MUKI_YOKO,
                           action: #selector(chooseYoko)))
        // ★v4.3★ 上下が実機と反対だった（親分が実機で確認・2026-08-13）
        //  旧: 上=ccw / 下=cw   →   新: 上=cw / 下=ccw
        //  ★理屈ではなく 実機で見た結果で決めた。ここは触るな。★
        menu.addItem(radio("縦・ホームボタンが 上",
                           on: nowMuki == MUKI_CW,
                           action: #selector(chooseCW)))
        menu.addItem(radio("縦・ホームボタンが 下",
                           on: nowMuki == MUKI_CCW,
                           action: #selector(chooseCCW)))

        menu.addItem(.separator())

        // ---- マウスの入り口（★iPadの辺 で言う。親分の指摘 2026-08-13）----
        let mouseItem = plain("マウスは iPadの \(iriguchiName(iriguchi)) から入る", nil)
        let mouseMenu = NSMenu()
        mouseMenu.autoenablesItems = false
        for key in iriguchiKeysInOrder() {
            let it = radio("iPadの \(iriguchiName(key)) から",
                           on: iriguchi == key,
                           action: #selector(chooseIriguchi(_:)))
            it.representedObject = key
            mouseMenu.addItem(it)
        }
        mouseMenu.addItem(.separator())
        mouseMenu.addItem(header("思った辺と違ったら 別のを選ぶ"))
        mouseItem.submenu = mouseMenu
        menu.addItem(mouseItem)

        menu.addItem(.separator())
        menu.addItem(plain("使い方", #selector(showGuide(_:))))

        statusItem.menu = menu
    }

    // ---- メニュー部品 ----

    func styled(_ s: String, size: CGFloat = MENU_FONT_SIZE,
                gray: Bool = false) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size)]
        if gray { attrs[.foregroundColor] = NSColor.secondaryLabelColor }
        return NSAttributedString(string: s, attributes: attrs)
    }

    func header(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.attributedTitle = styled(title, size: 13, gray: true)
        it.isEnabled = false
        return it
    }

    func plain(_ title: String, _ action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.attributedTitle = styled(title)
        it.target = self
        it.isEnabled = true
        return it
    }

    /// ●／○ を自分で書く。チェック印は小さくて見づらいため。
    func radio(_ title: String, on: Bool, action: Selector?) -> NSMenuItem {
        let mark = on ? "●  " : "○  "
        let it = NSMenuItem(title: mark + title, action: action, keyEquivalent: "")
        it.attributedTitle = styled(mark + title)
        it.target = self
        it.isEnabled = true
        return it
    }

    /// マウスが iPad の どの辺 から入ってくるか。
    ///
    ///  ★★ ここが「マウスの入り口」の対応表。直すならここ1か所だけ ★★
    ///
    ///  左が「器を本体のどこに置くか」、右が「メニューに出す文字」。
    ///
    ///      器を macの右 に置く  →  「iPadの 右 から入る」   左右は そのまま
    ///      器を macの左 に置く  →  「iPadの 左 から入る」   左右は そのまま
    ///      器を macの上 に置く  →  「iPadの 下 から入る」   上下は 逆
    ///      器を macの下 に置く  →  「iPadの 上 から入る」   上下は 逆
    ///
    ///  ★ホームボタンが 上 でも 下 でも 同じ表でよい★
    ///   （2026-08-13 親分が実機で両方 確認）
    ///
    ///   なぜ同じでよいか:
    ///    ホームボタンを上にする＝iPad を 物理的に 180度 回すということ。
    ///    そのとき くるりんパッ は 絵の倒す向きも 反対にしている。
    ///    ＝ 180度の回転が 2回。打ち消し合って 元に戻る。
    ///    だから 親分の目に見える「入ってくる辺」は 変わらない。
    ///
    ///  ★迷った経緯（同じ所をぐるぐる回らないために残す）★
    ///   ・「4つとも逆」にした版を1回作ったが、実機で2回とも
    ///     「左右が反対」と言われた。左右は そのまま が正しい。
    ///   ・向きによって表を変える版も作ったが、実機で
    ///     「ホームボタン上は すべて逆」と言われた。＝表は1つでよい。
    ///
    ///  ★理屈で書き換えるな。親分が実物を見て決めた値がすべて。★
    func iriguchiName(_ k: String) -> String {
        switch k {
        case "up":   return "下"      // 器を上に置くと iPadの下から入る
        case "down": return "上"      // 器を下に置くと iPadの上から入る
        case "left": return "左"
        default:     return "右"      // right
        }
    }

    /// メニューに並べる順番を 上 → 下 → 左 → 右 にする（親分の指示 2026-08-13）。
    ///  向きによって どのキーが どの辺になるかが変わるので、
    ///  キーの順番ではなく「見えている辺の名前」で並べ替える。
    func iriguchiKeysInOrder() -> [String] {
        let order = ["上", "下", "左", "右"]
        return ["right", "left", "up", "down"].sorted {
            (order.firstIndex(of: iriguchiName($0)) ?? 9)
          < (order.firstIndex(of: iriguchiName($1)) ?? 9)
        }
    }



    // ========================================================
    //  メニューが押されたとき
    // ========================================================

    @objc func chooseYoko() {
        // ★横は アプリを通さない。器を捨てて 素のSidecar に戻すだけ。
        stopDaemon()
        nowMuki = MUKI_YOKO
        refresh()
    }

    @objc func chooseCW()  { startDaemon(MUKI_CW) }
    @objc func chooseCCW() { startDaemon(MUKI_CCW) }

    @objc func chooseIriguchi(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        iriguchi = key
        let wasRunning = (nowMuki != MUKI_YOKO)
        let muki = nowMuki
        refresh()
        if wasRunning { startDaemon(muki) }   // 入れ直さないと位置は変わらない
    }

    @objc func quitApp() {
        stopDaemon()
        NSApp.terminate(nil)
    }


    // ========================================================
    //  デーモンの起動と停止
    // ========================================================

    func startDaemon(_ muki: String) {
        stopDaemon()

        //  ★間違い②の修正★
        //  途中で引き返す道が3本ある。そのどれかを通ったとき、
        //  メニューだけ「縦」のまま残ると、親分に嘘をつくことになる。
        //  だから先に「横」に戻しておき、成功したときだけ「縦」にする。
        nowMuki = MUKI_YOKO
        refresh()

        guard FileManager.default.fileExists(atPath: daemonURL.path) else {
            tell("中身（kururin_pa_daemon）が見つかりません",
                 "アプリの隣にあるはずのファイルがありません。\n\n"
                 + "探した場所：\n\(daemonURL.path)\n\n"
                 + "「6_アプリを作る.command」をもう一度ダブルクリックしてください。")
            return
        }

        // 画面収録の許可がないと、映像が1コマも届かない（真っ黒になる）
        if !CGPreflightScreenCaptureAccess() {
            guideScreenCapture()
            return
        }

        let p = Process()
        p.executableURL = daemonURL
        p.arguments = ["run", muki, String(byou), iriguchi]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.daemonEnded(proc, code) }
        }

        // 前回の脈が残っていると「固まっている」と誤判定するので消しておく
        try? FileManager.default.removeItem(atPath: heartbeatPath)

        do {
            try p.run()
        } catch {
            tell("起動できませんでした", "\(error.localizedDescription)")
            return
        }

        daemon = p
        daemonStartedAt = Date()
        nowMuki = muki
        refresh()
        startHeartbeatWatch()
    }

    /// ★命綱★ 中身が固まっていないか 2秒ごとに確かめる
    func startHeartbeatWatch() {
        stopHeartbeatWatch()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.daemon, p.isRunning else { return }
            // 起動直後は まだ脈が無い。20秒は待ってやる。
            if Date().timeIntervalSince(self.daemonStartedAt) < 20 { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: self.heartbeatPath)
            let beat = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            if Date().timeIntervalSince(beat) > 6 {
                kill(p.processIdentifier, SIGKILL)   // 返事が無い。問答無用。
            }
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    func stopHeartbeatWatch() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    func stopDaemon() {
        stopHeartbeatWatch()
        guard let p = daemon else { return }
        daemon = nil
        p.terminationHandler = nil      // 自分で止めたときは呼ばせない
        guard p.isRunning else { return }

        p.terminate()                   // SIGTERM → デーモンが自分で片付けて終わる
        let limit = Date().addingTimeInterval(3.0)
        while p.isRunning && Date() < limit {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// デーモンが 自分から 終わったとき（時間切れ・失敗・異常）
    func daemonEnded(_ proc: Process, _ code: Int32) {
        //  ★間違い③の修正★
        //  「daemon が nil なら通す」にしていたため、
        //  くろが自分で止めた直後の取りこぼしでも
        //  親分にエラーの窓が出てしまう恐れがあった。
        //  今 動かしている当人からの報告だけを受け取る。
        guard proc === daemon else { return }
        daemon = nil
        stopHeartbeatWatch()
        nowMuki = MUKI_YOKO
        refresh()

        switch code {
        case 0:
            break                       // 正常に終わっただけ。黙って横に戻す。
        case 6:
            //  ★v4.3★ 中身が「張り付きそうだ」と気づいて 自分から撤収した。
            //  これは成功。窓は消えている。黙って「横」に戻すだけでいい。
            break
        case 9:
            //  ★v4.3★ 中身が固まったので 命綱が殺した。
            break
        case 2:
            tell("iPad が見つかりません",
                 "先に iPad を Sidecar でつないでください。\n\n"
                 + "つなぎ方：\n"
                 + "1. iPad を 横向き に持つ\n"
                 + "2. 右上から下スワイプ → 回転ロックを オン\n"
                 + "3. その状態で Sidecar 接続\n"
                 + "4. つながってから この操作をやり直す")
        case 1:
            tell("縦の画面を作れませんでした",
                 "iPad をつなぎ直してから、もう一度お試しください。")
        case 5:
            tell("うまく置けなかったのでやめました",
                 "画面には何も出していません。\n"
                 + "iPad をつなぎ直してから、もう一度お試しください。")
        default:
            tell("止まりました（コード \(code)）",
                 "iPad をつなぎ直してから、もう一度お試しください。")
        }
    }


    // ========================================================
    //  お知らせの窓（老眼配慮：大きい字）
    // ========================================================

    func tell(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        let tf = NSTextField(wrappingLabelWithString: body)
        tf.font = NSFont.systemFont(ofSize: 15)
        tf.preferredMaxLayoutWidth = 420
        tf.setFrameSize(NSSize(width: 420, height: 10))
        tf.sizeToFit()
        a.accessoryView = tf
        a.addButton(withTitle: "わかった")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// ★v4.3★ 画面収録の許可の案内。
    ///
    ///  ★勝手に出る窓は macOS のものだけ。くるりんパッからは出さない。★
    ///   （親分の指示 2026-08-13。同じ設定を2回誘導されると迷うため）
    ///
    ///   許可が無いときは メニューの一番上に1行だけ出す。
    ///   押されたときだけ くるりんパッの案内窓を開く。
    func guideScreenCapture() {
        //  ★★ 自動で出す窓は macOS のものだけ ★★
        //   （親分の指示 2026-08-13:
        //     「システムが案内を出してくれるなら くるりんパッからは やめよう。
        //       2回 同じ設定を誘導されると、さっき設定したのに
        //       まだ何を設定するのかと迷う」）
        //
        //   CGRequestScreenCaptureAccess() は 毎回 呼ぶ。
        //   これを呼ばないと システム設定の「画面収録」の一覧に
        //   くるりんパッ が自動で追加されない。
        //   2回目以降に呼んでも macOS は窓を出さない（黙って返るだけ）。
        store.set(true, forKey: SettingKey.askedOS)
        _ = CGRequestScreenCaptureAccess()

        //   ★macOS の窓が出ないこともある★
        //    一度でも「拒否」か「許可」を答えた相手には、macOS は
        //    二度とあの窓を出さない。そのときは 画面に何も出ない。
        //    黙って何も起きないと 親分が困るので、
        //    メニューの一番上に「許可がありません」の行を出す。
        //    押したときだけ くるりんパッの案内窓を開く。
        //    ＝ 勝手に2枚出ることは 二度と無い。
        refresh()
    }

    @objc func showPermissionGuide() { askOpenSettings() }

    func askOpenSettings() {
        let a = NSAlert()
        a.messageText = "「画面収録」の許可が必要です"
        let body =
            "たてモニ は、作った縦の画面を撮って iPad に貼りつけます。\n"
            + "そのため「画面収録」の許可が要ります。\n\n"
            + "1. 下の「システム設定を開く」を押す\n"
            + "2. 一覧の「たてモニ」を オン にする\n"
            + "3. たてモニ を いったん終了して、もう一度開く\n\n"
            + "※許可を入れた直後は、一度アプリを開き直さないと有効になりません。"
        let tf = NSTextField(wrappingLabelWithString: body)
        tf.font = NSFont.systemFont(ofSize: 15)
        tf.preferredMaxLayoutWidth = 460
        tf.setFrameSize(NSSize(width: 460, height: 10))
        tf.sizeToFit()
        a.accessoryView = tf
        a.addButton(withTitle: "システム設定を開く")
        a.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(u)
            }
        }
    }


    // ========================================================
    //  使い方の窓
    // ========================================================

    //  ★v4.3★ 改行だらけだったのをやめた。
    //   文は普通に書いて、行間と段落の間隔で読みやすくする。
    //   （手で改行を入れると、窓の幅を変えたときに変な所で切れる）
    let guideText = """
    ★ 表示がおかしくなるのを防ぐ
    iPad は【横向き】で 回転ロック してください
    【縦向き】でロックすると 画面表示がおかしくなります
    ここだけは 面倒ですが 必ずお願いします
    ── 使う順番 ──
    1.  iPad を 横向き に持つ
    2.  画面の右上から 下へスワイプ
    3.  回転ロック 設定 オン にする
    4.  Sidecar でつなぐ
    5.  iPad を 使いたい向きに置く
    6.  メニューから 画像の向き を選ぶ
    7.  メニューから マウスの矢印が入ってくる辺 を選ぶ
    ── 知っておいて ──
    ● iPad を 直接 触っても効きません
    縦表示の間は タッチ操作 も ペン も効きません
    マウスで操作してください。
    ● Mac のディスプレイ設定について
    システム ディスプレイ設定に 画面が1枚 増えます
    全部で3つに見えます　縦表示時の 仮想モニターです
    「横（そのまま）」に戻せば 消えます。
    ● サイドバー・Touch Bar
    表示 / 非表示は システム ディスプレイ設定で変更
    ● 他の「拡張ディスプレイ」アプリと 一緒に使うとき
    DisplayLink など 他の拡張ディスプレイアプリと 同時に使うと
    正しく表示されないことがあります
    （モニターの接続台数が多いときに 起こりやすいです）
    うまく表示されないときは
    ・モニターや iPad を つなぐ順番
    ・アプリを 起動する順番
    を 入れ替えて 試してみてください
    """

    /// 使い方の文を 読みやすい形に組み立てる。
    ///  ・行間を広げる（老眼配慮）
    ///  ・見出し（★ ── ●）は 太字にして 前を1行分あける
    ///  ・番号の行は ぶら下げにして 折り返しても頭がそろうようにする
    func guideAttributed() -> NSAttributedString {
        //  ★v4.3★ 親分の指示で 2割 小さくした（18→14.5 / 19→15.5）。
        //   行間も詰めた。老眼配慮は残しつつ 一画面に収まるように。
        let bodyFont = NSFont.systemFont(ofSize: 14.5)
        let headFont = NSFont.systemFont(ofSize: 15.5, weight: .bold)
        let out = NSMutableAttributedString()

        for raw in guideText.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let isHead = line.hasPrefix("★") || line.hasPrefix("──") || line.hasPrefix("●")
            let isStep = line.first.map { "123456789".contains($0) } ?? false

            //  ★行間の考え方★
            //   親分が入れた改行は そのまま改行として見せる（穴を空けない）。
            //   まとまりの切れ目は 見出しの前だけ 大きく空ける。
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacing = isHead ? 5 : (isStep ? 2 : 1)
            p.paragraphSpacingBefore = isHead ? 12 : 0
            if isStep { p.headIndent = 22 }          // 折り返しの頭をそろえる

            out.append(NSAttributedString(string: line + "\n",
                                          attributes: [.font: isHead ? headFont : bodyFont,
                                                       .paragraphStyle: p,
                                                       .foregroundColor: NSColor.labelColor]))
        }
        return out
    }

    @objc func showGuide(_ sender: Any?) {
        if let w = guideWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let size = NSSize(width: 480, height: 540)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered,
                         defer: false)
        // ★バージョンは 窓のタイトルバーに出す（親分の指示 2026-08-13）。
        //   本文の中に帯を作ると、そのぶん本文が下に押されて
        //   最後の行がスクロールしないと見えなくなる。だからタイトルへ。
        w.title = "たてモニ の使い方　\(APP_VERSION)"
        w.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder

        let tv = NSTextView(frame: NSRect(origin: .zero, size: size))
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: 14.5)    // 実際の見た目は guideAttributed() が決める
        tv.textStorage?.setAttributedString(guideAttributed())
        tv.textContainerInset = NSSize(width: 22, height: 18)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: size.width,
                                                 height: CGFloat.greatestFiniteMagnitude)

        scroll.documentView = tv
        w.contentView = scroll

        // ★窓の高さは 本文の実物に合わせる（親分の指示 2026-08-13）。
        //   ★理屈より実物★
        //   行数を数えて高さを決めると必ずずれる。文を1行足しただけで
        //   また はみ出す。だから AppKit に実際に組ませて、
        //   その結果の高さを測って、窓をそこに合わせる。
        //   こうすれば あとで文を増やしても 自動でついてくる。
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            let textH = lm.usedRect(for: tc).height
            //  measure に失敗すると 0 に近い値が返る。
            //  そのときは 元の高さのまま（悪くしない）。
            if textH > 100 {
                let needed = ceil(textH) + 36 + 8      // 上下の余白18×2 ＋ 念のため
                let limit  = (NSScreen.main?.visibleFrame.height ?? 800) - 40
                w.setContentSize(NSSize(width: size.width,
                                        height: min(needed, limit)))
            }
        }
        w.center()
        guideWindow = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}


// ============================================================
//  入口
// ============================================================

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
