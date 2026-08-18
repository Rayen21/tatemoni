import Foundation
import CoreGraphics
import ObjectiveC
import AppKit
import QuartzCore
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// ============================================================
//  たてモニ（内部の本名: くるりんパッ）バックエンドデーモン  v3.8
//  v3.1 → v3.2: 張り付き対策（自動撤収）を入れた
//  v3.2 → v3.3: 本物のiPad画面を 器の外側へ逃がす（入り口を1つにする）
//  v3.3 → v3.4: 2026-08-18 findTarget() 修正・第1弾
//    外部モニタ(Thunderbolt等)がiPadより先に見つかると、
//    そのモニタをiPadと誤認識して縦の窓を貼るバグを直した（ここまでは実機確認済み）。
//    最初「EDID（モニター情報）を持たない画面をiPadとみなす」という
//    判定にしたが、★実機ログで確認したら外れていた★
//    （SidecarもThunboltモニタも、どちらも「EDIDあり」と出た）。
//    → v3.5で判定方法を差し替えた。
//    ★ビルド事故: 最初に書いたv3.4はnsScreenのスコープ間違いで
//      ビルドエラーになっていた（同日中に修正）。★
//  v3.4 → v3.5: 2026-08-18 findTarget() 修正・第2弾（★実機ログで確認できた★）
//    実機ログで、Sidecarの画面だけ vendor/model 番号が
//      vendor=0x6161706c ("aapl"=Apple) / model=0x69506164 ("iPad")
//    という特別な値になっていることが分かった。
//    普通の市販モニター（MSI MP273A）は vendor=0x3669/model=0x40b4 という
//    見るからに違う値だった。このaapl/iPadの組を判定の主役にした。
//    findTarget() 以外は無変更。
//  v3.5 → v3.6: 2026-08-18 DisplayLink等との衝突を検知する機能を追加
//    親分の実機（USB1ポート分岐でDisplayLinkモニタ2台＋Sidecar）で、
//    たてモニを縦にした瞬間、DisplayLinkの外部モニタがミラー表示に
//    変わってしまう現象が報告された。DisplayLinkモニタの接続台数を
//    減らすと直ったことから、画面（実物・仮想を問わず）の合計数か
//    USB帯域のどちらかが上限に近いと起きる、という見立て。
//    ★台数のしきい値は環境ごとに違うので、先読みしてブロックする
//      のではなく「並べ替えの前後でミラーになった画面がないか」を
//      実際に確かめてログへ知らせる方式にした（理屈より実物）。
//    findTarget() は無変更。DaemonDisplayManagerに
//      snapshotMirrorState() を追加し、start() で前後比較している。
//  v3.6 → v3.7: 2026-08-18 6章【B】対応（公開前 必須の修正）
//    内蔵画面が無いMac（Mac mini / Mac Studio / Mac Pro）で使うと、
//    findTarget()が「メイン画面（＝操作中のモニタ）」をiPadと
//    誤認識し、そこに真っ黒な最前面の窓を出してマウスもキー入力も
//    素通りになる=操作不能になる不具合があった。
//    findTarget()の候補集めでメイン画面を除外し、窓を出す直前の
//    最終チェック（3.5 関所）でも「相手がメインならやめる」を追加。
//    親分のMacはメイン＝内蔵なので、この修正で今までの動作は
//    1ミリも変わらない（★2026-08-18 実機で確認済み・問題なし★）。
//  v3.7 → v3.8: 2026-08-18 6章【C】【D】対応
//    【C】キャプチャに失敗すると黒い窓が残ったまま無反応になる問題:
//      キャプチャ開始が成功した扱いになっても、実際には1コマも
//      映像が来ないまま止まる事故があったため、開始から10秒待って
//      1コマ目がまだ来ていなければ kururinBailOut() で撤収するように
//      した（FrameReceiver.reportedFirstFrame を外から読めるようにし、
//      beginCapture() の中でDispatchQueue.main.asyncAfterで確認）。
//    【D】皮（親アプリ）を強制終了するとデーモンと黒い窓が生き残る問題:
//      kururinBeat()（1秒ごとに呼ばれる心臓の鼓動）の中で
//      getppid() == 1 かどうかを見るようにした。皮が消えて孤児化すると
//      親PIDがlaunchd(=1)に変わるので、それを検知して撤収する。
//    ★2026-08-18時点: どちらも コード修正のみ。実機でのビルド・
//      動作確認は これから。★
//
//  v2.0 からの変更:
//   ・仮想ディスプレイを作る処理を1か所にまとめた
//     （調査用と本番用でコードが分かれていて、
//       調査用だけ設定が足りずに失敗していたため）
//   ・失敗した段階が必ずログに残るようにした
//   ・画面サイズの取得を CGDisplayBounds 基準に統一した
//
//  実測済みの本物のAPI（macOS 26.6.1 のランタイムから取得）:
//   CGVirtualDisplayDescriptor : name / maxPixelsWide / maxPixelsHigh
//                                sizeInMillimeters / queue / vendorID
//                                productID / serialNum / terminationHandler
//   CGVirtualDisplay           : -initWithDescriptor:  -applySettings:
//                                displayID / rotation (読み取り専用)
//   CGVirtualDisplaySettings   : modes / hiDPI / rotation
//   CGVirtualDisplayMode       : -initWithWidth:height:refreshRate:
// ============================================================


// MARK: - ログ

final class Log {
    static let shared = Log()
    private var fileURL: URL?

    private init() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let exeURL = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: cwd).standardized
        var dir = exeURL.deletingLastPathComponent()

        if dir.path.hasSuffix("/Contents/MacOS") {
            dir = dir.deletingLastPathComponent()
                     .deletingLastPathComponent()
                     .deletingLastPathComponent()
        }

        let candidate = dir.appendingPathComponent("たてモニ動作ログ.txt")
        fileURL = FileManager.default.isWritableFile(atPath: dir.path)
            ? candidate
            : URL(fileURLWithPath: "/tmp/たてモニ動作ログ.txt")

        write("\n=========================================\n"
            + "起動: \(Self.stamp())\n"
            + "実行ファイル: \(exeURL.path)\n"
            + "=========================================\n")
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    private func write(_ s: String) {
        guard let url = fileURL, let data = s.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    func say(_ message: String) {
        let line = "[\(Self.stamp())] \(message)"
        print(line); fflush(stdout)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        write(line + "\n")
    }

    var path: String { fileURL?.path ?? "(なし)" }
}

let logger = Log.shared
func say(_ s: String) { logger.say(s) }


// MARK: - Objective-C の非公開クラスを呼ぶ道具

private let dylibHandle = dlopen(nil, RTLD_LAZY)
private let msgSendPtr: UnsafeMutableRawPointer? = dlsym(dylibHandle, "objc_msgSend")

private typealias FnNoArg   = @convention(c) (AnyObject, Selector) -> AnyObject?
private typealias FnObjArg  = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
private typealias FnBoolArg = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
private typealias FnMode    = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?

private func objcAlloc(_ cls: AnyClass) -> AnyObject? {
    guard let p = msgSendPtr else { return nil }
    return unsafeBitCast(p, to: FnNoArg.self)(cls as AnyObject, NSSelectorFromString("alloc"))
}

private func objcCall(_ obj: AnyObject, _ sel: String, _ arg: AnyObject?) -> AnyObject? {
    guard let p = msgSendPtr else { return nil }
    return unsafeBitCast(p, to: FnObjArg.self)(obj, NSSelectorFromString(sel), arg)
}

private func objcCallBool(_ obj: AnyObject, _ sel: String, _ arg: AnyObject?) -> Bool {
    guard let p = msgSendPtr else { return false }
    return unsafeBitCast(p, to: FnBoolArg.self)(obj, NSSelectorFromString(sel), arg).boolValue
}

private func makeMode(width: UInt32, height: UInt32, refreshRate: Double) -> AnyObject? {
    guard let cls = NSClassFromString("CGVirtualDisplayMode"),
          let raw = objcAlloc(cls),
          let p = msgSendPtr else { return nil }
    return unsafeBitCast(p, to: FnMode.self)(
        raw, NSSelectorFromString("initWithWidth:height:refreshRate:"),
        width, height, refreshRate)
}


// MARK: - 画面管理

final class DaemonDisplayManager {
    static let shared = DaemonDisplayManager()

    private var virtualDisplay: AnyObject?
    private var virtualDisplayID: CGDirectDisplayID?
    private let vdQueue = DispatchQueue(label: "com.yama.kururin-pa.virtualdisplay")
    /// 仮想ディスプレイを作るたびに変える通し番号（同じ番号だとOSが使い回す恐れがあるため）
    private var serialCounter: UInt32 = 1

    struct TargetInfo {
        let id: CGDirectDisplayID
        let pointWidth: Int      // 見かけの大きさ 例 1080
        let pointHeight: Int     // 見かけの大きさ 例 810
        let refreshRate: Double
        var pixelWidth: Int { pointWidth * 2 }   // Retina 前提
        var pixelHeight: Int { pointHeight * 2 }

        /// 縦横を入れ替えたもの。
        /// 例: iPad の Sidecar 1080x810（横長）→ 810x1080（縦長）
        /// 「画面を回転させる」のではなく「最初から縦長の器を作る」ための値。
        var swapped: TargetInfo {
            TargetInfo(id: id,
                       pointWidth: pointHeight,
                       pointHeight: pointWidth,
                       refreshRate: refreshRate)
        }
    }

    // ---- 相手（iPad / Sidecar）を探す ----

    /// ★2026-08-18 追加。CGDirectDisplayID から NSScreen を引く。
    ///   KururinRunner にも同じ役目の private メソッドがあるが、
    ///   private はクラスをまたげないので、こちらにも用意した。
    ///   （★これがv3.4のビルド失敗の原因だった。ここで直した★）
    private func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { KururinRunner.displayID(of: $0) == id }
    }

    func findTarget() -> TargetInfo? {
        let maxDisplays: UInt32 = 16
        var list = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0

        guard CGGetActiveDisplayList(maxDisplays, &list, &count) == .success else {
            say("エラー: 画面一覧が取得できません")
            return nil
        }

        say("接続中の画面は \(count) 台")
        for i in 0..<Int(count) {
            let id = list[i]
            let b = CGDisplayBounds(id)
            say("  ID=\(id)  本体内蔵=\(CGDisplayIsBuiltin(id) != 0)  メイン=\(CGDisplayIsMain(id) != 0)  \(Int(b.width))x\(Int(b.height))")
        }

        // ★候補（内蔵でも器でもない、有効な外部画面）を全部集める。
        //   外部モニタ（Thunderbolt/HDMI等）が iPad より先に見つかると、
        //   今までは そのモニタを iPad と決めつけて縦の窓を貼っていた。
        //
        //   ★2026-08-18 v2で「EDIDの有無」で見分けようとしたが、
        //     実機ログで確認したところ 外れていた（両方とも EDIDあり=true だった）。
        //     Sidecarも「本物のモニターらしい情報」を持っていた。
        //
        //   ★2026-08-18 v3（★実機ログで確認できた・確定★）:
        //     実機ログで、Sidecarの画面だけ vendor/model 番号が
        //     ASCIIで読むと文字になる特別な値だと分かった。
        //       vendor = 0x6161706c = "aapl"（Apple）
        //       model  = 0x69506164 = "iPad"
        //     普通の市販モニター（今回は MSI MP273A）は
        //     vendor=0x3669 / model=0x40b4 のような、
        //     文字には見えない普通のメーカーコードだった。
        //     この "aapl"/"iPad" の組は macOS 自身がSidecarの
        //     仮想ディスプレイに付けている値なので、
        //     iPad側の名前のようにユーザーが変えることはできない。
        //     ★これを判定の主役にする。★
        //     名前判定（★実機で見たら "Sidecar Display (AirPlay)" で、
        //       「iPad」という文字は入っていなかった★）は
        //       次点として残すが、あまり頼りにしない。
        //   候補が1台しかない環境では、この判定を経ても
        //     結局その1台が選ばれるので、挙動は変わらない。
        let sidecarVendor: UInt32 = 0x6161706c   // "aapl"（2026-08-18 実機で確認）
        let sidecarModel:  UInt32 = 0x69506164   // "iPad"（2026-08-18 実機で確認）
        var candidates: [TargetInfo] = []
        for i in 0..<Int(count) {
            let id = list[i]
            if CGDisplayIsBuiltin(id) != 0 { continue }
            // ★2026-08-18 v3.7で追加: 内蔵画面が無いMac（Mac mini等）では
            //   「メイン画面（＝操作しているモニタ）」が候補に混ざってしまい、
            //   最悪それをiPadと誤認識して真っ黒な窓で覆ってしまう事故があった
            //   （6章【B】）。メイン画面は常に除外する。
            if CGDisplayIsMain(id) != 0 { continue }
            if id == virtualDisplayID { continue }
            guard CGDisplayIsActive(id) != 0 else { continue }

            // ★見かけの大きさは CGDisplayBounds を正とする。
            //   CGDisplayCopyDisplayMode は Sidecar だと実態とズレた値を返すことがあった。
            let b = CGDisplayBounds(id)
            let rate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
            candidates.append(TargetInfo(
                id: id,
                pointWidth: Int(b.width),
                pointHeight: Int(b.height),
                refreshRate: rate > 0 ? rate : 60.0
            ))
        }

        guard !candidates.isEmpty else {
            say("エラー: iPad（Sidecar）等の外部画面が見つかりません")
            return nil
        }

        var info = candidates[0]
        if candidates.count > 1 {
            say("★外部画面が複数見つかりました。判別のため、それぞれの情報を記録します。")
            for c in candidates {
                let name = nsScreen(for: c.id)?.localizedName ?? "（名前不明）"
                let vendor = CGDisplayVendorNumber(c.id)
                let model = CGDisplayModelNumber(c.id)
                let isSidecar = (vendor == sidecarVendor && model == sidecarModel)
                say("  候補 ID=\(c.id)  名前=\(name)  vendor=0x\(String(vendor, radix: 16))  model=0x\(String(model, radix: 16))  Sidecarの印=\(isSidecar)")
            }

            let sidecarMatch = candidates.filter {
                CGDisplayVendorNumber($0.id) == sidecarVendor && CGDisplayModelNumber($0.id) == sidecarModel
            }
            if sidecarMatch.count == 1 {
                info = sidecarMatch[0]
                say("★Sidecarの印（vendor=aapl / model=iPad）を持つ画面が1台だけだったので、それを選びました（ID=\(info.id)）。")
            } else if let named = candidates.first(where: {
                guard let n = nsScreen(for: $0.id)?.localizedName else { return false }
                return n.contains("iPad") || n.contains("Sidecar")
            }) {
                info = named
                say("★Sidecarの印だけでは決められなかったので、名前に「iPad」か「Sidecar」が含まれる画面を選びました（ID=\(info.id)）。")
            } else {
                say("★Sidecarの印でも名前でも判別できなかったので、見つかった順で最初の画面を選びました（ID=\(info.id)）。")
            }
        }

        say("相手の画面: ID=\(info.id)  見かけ \(info.pointWidth)x\(info.pointHeight)  \(Int(info.refreshRate))Hz")
        return info
    }

    // ---- 仮想ディスプレイを1台作る（本番も調査もここを通す）----

    struct BuiltDisplay {
        let object: AnyObject
        let id: CGDirectDisplayID
        let appliedRotation: UInt32
        let bounds: CGRect
    }

    /// 失敗したら、どの段階で失敗したかを必ずログに残す。
    func buildDisplay(target: TargetInfo, rotation: UInt32, name: String) -> BuiltDisplay? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass   = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let displayClass    = NSClassFromString("CGVirtualDisplay") else {
            say("  失敗[段階1]: 仮想ディスプレイの部品クラスが見つかりません")
            return nil
        }

        // --- 段階2: Descriptor ---
        serialCounter += 1
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(UInt32(target.pixelWidth), forKey: "maxPixelsWide")
        descriptor.setValue(UInt32(target.pixelHeight), forKey: "maxPixelsHigh")
        descriptor.setValue(CGSize(width: 251, height: 188), forKey: "sizeInMillimeters")
        descriptor.setValue(UInt32(0x4B50), forKey: "vendorID")
        descriptor.setValue(UInt32(0x0001), forKey: "productID")
        descriptor.setValue(serialCounter, forKey: "serialNum")
        descriptor.setValue(vdQueue, forKey: "queue")

        // --- 段階3: alloc ---
        guard let raw = objcAlloc(displayClass) else {
            say("  失敗[段階3]: alloc できません（objc_msgSend が取れていない可能性）")
            return nil
        }

        // --- 段階4: initWithDescriptor: ---
        guard let display = objcCall(raw, "initWithDescriptor:", descriptor) else {
            say("  失敗[段階4]: initWithDescriptor: が nil を返しました")
            return nil
        }

        // --- 段階5: モード ---
        guard let mode = makeMode(width: UInt32(target.pointWidth),
                                  height: UInt32(target.pointHeight),
                                  refreshRate: target.refreshRate) else {
            say("  失敗[段階5]: 表示モードを作れません")
            return nil
        }

        // --- 段階6: Settings ---
        let settings = settingsClass.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(UInt32(1), forKey: "hiDPI")
        settings.setValue(rotation, forKey: "rotation")

        // --- 段階7: applySettings: ---
        let applied = objcCallBool(display, "applySettings:", settings)
        if !applied {
            say("  失敗[段階7]: applySettings が false（rotation=\(rotation) が無効かもしれません）")
            return nil
        }

        // --- 段階8: displayID を待つ ---
        var did: UInt32 = 0
        for _ in 1...25 {
            if let n = (display as? NSObject)?.value(forKey: "displayID") as? UInt32, n != 0 {
                did = n; break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard did != 0 else {
            say("  失敗[段階8]: displayID が返ってきません")
            return nil
        }

        let readBack = ((display as? NSObject)?.value(forKey: "rotation") as? UInt32) ?? 9999
        return BuiltDisplay(object: display, id: did,
                            appliedRotation: readBack, bounds: CGDisplayBounds(did))
    }

    // ---- 本番 ----

    func setupVirtualDisplay(target: TargetInfo, rotation: UInt32) -> CGDirectDisplayID? {
        say("仮想ディスプレイを作ります（元 \(target.pointWidth)x\(target.pointHeight) / 回転 \(rotation)）")
        guard let built = buildDisplay(target: target, rotation: rotation, name: "たてモニ") else {
            return nil
        }
        virtualDisplay = built.object
        virtualDisplayID = built.id
        say("成功: ID=\(built.id)  形=\(Int(built.bounds.width))x\(Int(built.bounds.height))  適用された回転=\(built.appliedRotation)")
        if rotation != 0 && built.appliedRotation != rotation {
            say("⚠️ 指定した回転 \(rotation) が \(built.appliedRotation) になっています（無視された）")
        }
        return built.id
    }

    // ---- ミラーリング ----

    func applyMirroring(targetID: CGDirectDisplayID) -> Bool {
        guard let masterID = virtualDisplayID else { return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        let err = CGConfigureDisplayMirrorOfDisplay(cfg, targetID, masterID)
        if err != .success {
            say("ミラーリング設定でエラー: \(err.rawValue)")
            CGCancelDisplayConfiguration(cfg)
            return false
        }
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }

    func removeMirroring() {
        guard let target = findTarget() else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, target.id, kCGNullDirectDisplay)
        _ = CGCompleteDisplayConfiguration(cfg, .permanently)
        say("ミラーリングを解除しました")
    }

    // ---- 他の画面のミラー巻き込み検知（2026-08-18 追加）----
    //  ★台数の上限を先読みしてブロックするのではなく、
    //   実際にミラーへ切り替わった画面があるかどうかを「前後」で比較して確かめる。
    //   （理屈より実物。DisplayLink等の閾値は環境ごとに違うので決め打ちしない）
    //  excluding には iPad(target) と 器(virtualDisplayID) を渡す。
    //  戻り値: [画面ID: その画面が今ミラーしている相手のID（0ならミラーしていない）]
    func snapshotMirrorState(excluding: Set<CGDirectDisplayID>) -> [CGDirectDisplayID: CGDirectDisplayID] {
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        var result: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        guard CGGetActiveDisplayList(16, &list, &count) == .success else { return result }
        for i in 0..<Int(count) {
            let id = list[i]
            if excluding.contains(id) { continue }
            result[id] = CGDisplayMirrorsDisplay(id)
        }
        return result
    }

    func cleanup() {
        if virtualDisplay != nil {
            removeMirroring()
            virtualDisplay = nil
            virtualDisplayID = nil
            say("片付け完了")
        }
    }

    // ---- 回転の総当たり調査 ----

    func probeRotation(target: TargetInfo) {
        say("")
        say("======== 回転の総当たり調査 ここから ========")
        say("横向きの器 \(target.pointWidth)x\(target.pointHeight) を作り、")
        say("縦長（\(target.pointHeight)x\(target.pointWidth)）になる値を探します。")
        say("")

        var winners: [UInt32] = []

        for candidate in [UInt32(0), 1, 2, 3, 90, 180, 270] {
            say("--- rotation = \(candidate) を試す ---")
            guard let built = buildDisplay(target: target,
                                           rotation: candidate,
                                           name: "たてモニ調査\(candidate)") else {
                say("  → 作れませんでした")
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                continue
            }

            let w = Int(built.bounds.width), h = Int(built.bounds.height)
            var verdict: String
            if w == target.pointHeight && h == target.pointWidth {
                verdict = "★★★ 縦長になった！ これが正解"
                winners.append(candidate)
            } else if w == target.pointWidth && h == target.pointHeight {
                verdict = "横のまま（効いていない）"
            } else {
                verdict = "予想外の形"
            }
            say("  ID=\(built.id)  読み返し=\(built.appliedRotation)  形=\(w)x\(h)  → \(verdict)")

            // 次へ行く前に確実に手放す
            _ = built.object
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        }

        say("")
        if winners.isEmpty {
            say("結論: rotation では回りませんでした。別の作戦が必要です。")
        } else {
            say("結論: 正解の値は \(winners.map(String.init).joined(separator: " または ")) です。")
        }
        say("======== 回転の総当たり調査 ここまで ========")
        say("")
    }
}


// MARK: - 映像の受け取り口
//
//  仮想ディスプレイ(縦長)の中身を ScreenCaptureKit で受け取り、
//  そのまま CALayer に貼る。CALayer 側が90度傾いているので、
//  貼るだけで「回った絵」になる。
//  ★画面を回転させているのではない。回した絵を描いている。★

final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate {
    private let videoLayer: CALayer
    private var frameCount = 0
    // ★v3.8★ 6章【C】対応: 「10秒経っても1コマ目が来なければ撤収」の
    //   判定に使うため、外から読めるようにした（書けるのはこのクラスだけ）。
    private(set) var reportedFirstFrame = false

    init(layer: CALayer) {
        self.videoLayer = layer
        super.init()
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        // 「中身が変わっていないコマ」は捨てる（無駄な描き直しを防ぐ）
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                     createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer) else { return }
        let surface = surfaceRef.takeUnretainedValue()

        frameCount += 1
        let n = frameCount
        let first = !reportedFirstFrame
        if first { reportedFirstFrame = true }

        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.videoLayer.contents = surface
            CATransaction.commit()
            if first { say("✅ 1コマ目が届きました。iPadに映っているはずです。") }
            if n % 600 == 0 { say("  （動作中: \(n) コマ目）") }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        say("❌ 映像が止まりました: \(error.localizedDescription)")
        // ★v3.2★ 映像が止まった＝もう正しい絵は出せない。窓を残すと張り付く。
        kururinBailOut("映像が止まりました（\(error.localizedDescription)）")
    }
}


// MARK: - 本番モード（縦長の器を作って、iPadに傾けて映す）

final class KururinRunner {
    private var window: NSWindow?
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    private var virtualObject: AnyObject?
    private var watchdog: Timer?          // ★v3.2★ 0.5秒ごとの見張り

    /// ★最優先★ とにかく今すぐ 見えなくする。片付けはそのあと。
    func hideRightNow() {
        watchdog?.invalidate(); watchdog = nil
        if let w = window {
            w.alphaValue = 0.0
            w.orderOut(nil)
        }
    }

    /// ③ 0.5秒ごとに「窓はまだ iPad の上に正しく乗っているか」を確かめる。
    ///   ★AppKit には聞かない。AppKit は嘘をつく。WindowServer に聞く。★
    func armWatchdog(padID: CGDirectDisplayID, virtualID: CGDirectDisplayID, want: CGRect) {
        kururinPadID = padID
        kururinVirtualID = virtualID
        kururinWantRect = want
        kururinArmed = true
        say("★ 見張り開始。0.5秒ごとに窓の位置を確かめます。")
        say("　 ズレたら／iPadが外れたら 自動で撤収します。")

        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard kururinArmed, !kururinBailedOut, let self else { return }

            // 1) iPad と 縦の器 がまだ生きているか
            if CGDisplayIsActive(kururinPadID) == 0 {
                kururinBailOut("iPad の画面が無くなりました（Sidecar が外れた）"); return
            }
            if CGDisplayIsActive(kururinVirtualID) == 0 {
                kururinBailOut("縦の器が無くなりました"); return
            }

            // 2) iPad の画面が動いていないか
            let now = CGDisplayBounds(kururinPadID)
            if abs(now.origin.x - kururinWantRect.origin.x) > 2
            || abs(now.origin.y - kururinWantRect.origin.y) > 2
            || abs(now.width    - kururinWantRect.width)    > 2
            || abs(now.height   - kururinWantRect.height)   > 2 {
                kururinBailOut("iPad の画面が動きました"
                    + "（今: \(Int(now.origin.x)),\(Int(now.origin.y))"
                    + " \(Int(now.width))x\(Int(now.height)))"); return
            }

            // 3) 窓が iPad の上から ずれていないか
            guard let w = self.window, let real = Self.realBounds(of: w) else {
                kururinBailOut("窓が見つかりません"); return
            }
            if abs(real.origin.x - kururinWantRect.origin.x) > 2
            || abs(real.origin.y - kururinWantRect.origin.y) > 2
            || abs(real.width    - kururinWantRect.width)    > 2
            || abs(real.height   - kururinWantRect.height)   > 2 {
                kururinBailOut("窓が iPad の上からずれました"
                    + "（今: \(Int(real.origin.x)),\(Int(real.origin.y))"
                    + " \(Int(real.width))x\(Int(real.height)))")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    /// CoreGraphics の座標（左上が原点・下向きがプラス）を
    /// AppKit の座標（本体画面の左下が原点・上向きがプラス）に直す。
    /// ★NSScreen.frame は当てにならないので、自分で計算する。
    static func cgToAppKit(_ b: CGRect) -> NSRect {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return NSRect(x: b.origin.x,
                      y: mainHeight - b.origin.y - b.height,
                      width: b.width,
                      height: b.height)
    }

    /// WindowServer（OSの本体）に「その窓は実際どこにあるのか」を直接聞く。
    /// AppKit の自己申告ではなく、これが真実。
    static func realBounds(of win: NSWindow) -> CGRect? {
        let wid = CGWindowID(win.windowNumber)
        guard wid != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid)
                as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: dict as! CFDictionary)
    }

    /// clockwise = true なら 時計回りに倒す
    /// limitSeconds > 0 なら その秒数で自動終了する（安全装置）
    /// entry = 器を置く場所（right / left / up / down）＝ マウスの入り口
    func start(clockwise: Bool, limitSeconds: Int, entry: String = "right") {
        let manager = DaemonDisplayManager.shared

        // ---- 1. iPad(Sidecar)を探す ----
        guard let target = manager.findTarget() else {
            say("中止: 先に iPad を Sidecar でつないでください")
            exit(2)
        }
        // 器を作る前の iPad の位置を覚えておく（あとで元に戻すため）
        let iPadOrigin = CGDisplayBounds(target.id).origin
        let mainBounds = CGDisplayBounds(CGMainDisplayID())

        // ★2026-08-18追加: 器を作る前の「他の画面のミラー状態」を覚えておく。
        //  あとで比較して、たてモニが原因で新しくミラーになった画面がないか調べる。
        let mirrorBefore = manager.snapshotMirrorState(excluding: [target.id])

        // ---- 2. 縦長の器を作る（tateモードで成功済みの手順そのまま）----
        let tate = target.swapped
        say("")
        say("縦長の器を作ります: \(tate.pointWidth)x\(tate.pointHeight)"
            + "（実ピクセル \(tate.pixelWidth)x\(tate.pixelHeight)）")
        guard let built = manager.buildDisplay(target: tate, rotation: 0,
                                               name: "たてモニ縦") else {
            say("中止: 縦長の器を作れませんでした")
            exit(1)
        }
        virtualObject = built.object
        let vw = Int(built.bounds.width), vh = Int(built.bounds.height)
        say("できた: ID=\(built.id)  形=\(vw)x\(vh)")
        guard vw == tate.pointWidth && vh == tate.pointHeight else {
            say("中止: 器の形が想定と違います（\(vw)x\(vh)）")
            exit(1)
        }

        // ---- 2.5 器を「本体画面の右どなり」に押しやり、iPadを元の位置に戻す ----
        //  ★根本原因への対処。
        //   器を作ると macOS が勝手に並べ替えて iPad を左へ押しやる（-1080 → -1890）。
        //   AppKit はこの押しやりに気づかないので、座標が食い違う。
        //   だったら「iPad を動かさせなければいい」。
        //   器は本体画面の右どなりに置き、iPad は元の位置に戻す。
        //  ★器を置く場所 = マウスの入り口★
        //   本体画面の どの辺 から出ると 器 に入るかは、器の位置で決まる。
        //   right（既定）は 2026-08-13 に実機で成功した配置そのもの。
        let vW = CGFloat(vw), vH = CGFloat(vh)
        var vOrigin: CGPoint
        switch entry {
        case "left":  vOrigin = CGPoint(x: mainBounds.minX - vW, y: 0)
        case "up":    vOrigin = CGPoint(x: 0, y: mainBounds.minY - vH)
        case "down":  vOrigin = CGPoint(x: 0, y: mainBounds.maxY)
        default:      vOrigin = CGPoint(x: mainBounds.maxX, y: 0)
        }

        //  ★v3.3 2026-08-13 実機の測定でわかったこと★
        //
        //  iPad の画面（本物のSidecar画面）は、器 の さらに外側 へ必ず逃がす。
        //
        //  なぜか:
        //   v3.2 までは「left を選んだときだけ」逃がしていた。
        //   その結果、left 以外では 本物のSidecar画面が
        //   本体画面の となり に残ったままになり、
        //   マウスを そちらへ動かすと「本物の画面」に入ってしまった。
        //   本物の画面は 黒い窓で覆われているので、
        //   親分の目には「入り口が2つある」ように見えていた。
        //
        //  実機の記録（ホームボタン下・2026-08-13）:
        //   右を選択 → 右へ動かすと 器に入る（正しい）
        //              左へ動かすと 本物の画面に入る（まぎらわしい）
        //   左を選択 → 左へ動かすと 器に入る。他の向きは行き止まり
        //              ＝ left だけ逃がしていたから 1つだけだった
        //
        //  だから 4方向とも 器の外側へ逃がす。入り口は必ず1つになる。
        let vRect = CGRect(origin: vOrigin, size: CGSize(width: vW, height: vH))
        let iSize = CGSize(width: CGFloat(target.pointWidth), height: CGFloat(target.pointHeight))
        var iOrigin: CGPoint
        switch entry {
        case "left":  iOrigin = CGPoint(x: vRect.minX - iSize.width, y: 0)
        case "up":    iOrigin = CGPoint(x: 0, y: vRect.minY - iSize.height)
        case "down":  iOrigin = CGPoint(x: 0, y: vRect.maxY)
        default:      iOrigin = CGPoint(x: vRect.maxX, y: 0)
        }
        say("  （本物のiPad画面は 器の外側 (\(Int(iOrigin.x)),\(Int(iOrigin.y))) へ逃がします）")
        _ = iPadOrigin

        say("")
        say("画面の並びを整えます（マウスの入り口=\(entry)"
            + " / 器を(\(Int(vOrigin.x)),\(Int(vOrigin.y)))へ"
            + " / iPadを(\(Int(iOrigin.x)),\(Int(iOrigin.y)))へ）…")
        var cfg: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&cfg) == .success {
            CGConfigureDisplayOrigin(cfg, built.id, Int32(vOrigin.x), Int32(vOrigin.y))
            CGConfigureDisplayOrigin(cfg, target.id, Int32(iOrigin.x), Int32(iOrigin.y))
            // .forSession = 一時的な変更。再起動すれば親分の元の並びに戻る。
            let r = CGCompleteDisplayConfiguration(cfg, .forSession)
            say(r == .success ? "  並べ替え成功" : "  並べ替え失敗（\(r.rawValue)）そのまま進みます")
        } else {
            say("  並べ替えを始められませんでした。そのまま進みます")
        }

        // AppKit に変化を知らせる時間を与える
        for _ in 1...15 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        // 整えたあとの並びを両方の目線で記録する（食い違いがあれば一目で分かる）
        var cgList = [CGDirectDisplayID](repeating: 0, count: 16)
        var cgCount: UInt32 = 0
        if CGGetActiveDisplayList(16, &cgList, &cgCount) == .success {
            say("CoreGraphics から見た並び（\(cgCount)台）:")
            for i in 0..<Int(cgCount) {
                let b = CGDisplayBounds(cgList[i])
                say("   ID=\(cgList[i])  位置(\(Int(b.origin.x)),\(Int(b.origin.y)))"
                    + "  大きさ \(Int(b.width))x\(Int(b.height))")
            }
        }
        say("AppKit から見た並び（\(NSScreen.screens.count)台）:")
        for s in NSScreen.screens {
            say("   ID=\(Self.displayID(of: s).map(String.init) ?? "?")"
                + "  位置(\(Int(s.frame.origin.x)),\(Int(s.frame.origin.y)))"
                + "  大きさ \(Int(s.frame.width))x\(Int(s.frame.height))")
        }

        // ★2026-08-18追加: 並べ替えの前後でミラーになった画面がないか確認する。
        //  DisplayLink等のUSB外部モニタは、画面（本物・仮想を問わず）が増えると
        //  自動でミラーに切り替わることがあると実機で確認できた（2026-08-18）。
        //  台数の閾値は環境（USBの繋ぎ方など）によって違うので決め打ちせず、
        //  「実際にミラーへ変わったかどうか」だけを見る。
        let mirrorAfter = manager.snapshotMirrorState(excluding: [target.id, built.id])
        for (id, mirrorTo) in mirrorAfter {
            let wasMirroring = (mirrorBefore[id] ?? 0) != 0
            let isMirroringNow = mirrorTo != 0
            if !wasMirroring && isMirroringNow {
                let name = nsScreen(for: id)?.localizedName ?? "（名前不明）"
                say("")
                say("⚠️ 画面ID=\(id)（\(name)）が、たてモニを縦にしたタイミングでミラー表示に変わりました。")
                say("   DisplayLink等のUSB外部モニタをお使いの場合、接続台数を減らすと直ることがあります。")
            }
        }

        // ---- 2.6 窓を置くのは アプリが動き出してから ----
        //  ★前回の失敗の原因。
        //   app.run() の前に窓を出しても、WindowServer にはまだ登録されない。
        //   だから「その窓どこ？」と聞いても答えが返ってこなかった。
        //   main queue に予約すれば app.run() が始まった直後に実行される。
        DispatchQueue.main.async {
            self.placeAndCapture(target: target,
                                 virtualID: built.id,
                                 vw: vw, vh: vh,
                                 pixelW: tate.pixelWidth, pixelH: tate.pixelHeight,
                                 clockwise: clockwise, limitSeconds: limitSeconds)
        }
    }

    private func placeAndCapture(target: DaemonDisplayManager.TargetInfo,
                                 virtualID: CGDirectDisplayID,
                                 vw: Int, vh: Int,
                                 pixelW: Int, pixelH: Int,
                                 clockwise: Bool, limitSeconds: Int) {

        // ---- 3. iPad画面の上に 枠なしの窓 を置く ----
        //  ★NSScreen.frame は使わない。
        //   AppKit は仮想ディスプレイの存在を知らず、iPadの位置も古いままだった。
        //   CGDisplayBounds（CoreGraphics）だけが正しい値を返す。
        let iPadCG = CGDisplayBounds(target.id)
        let f = Self.cgToAppKit(iPadCG)
        let scale = nsScreen(for: target.id)?.backingScaleFactor ?? 2.0
        say("iPadの本当の位置(CG): 原点(\(Int(iPadCG.origin.x)),\(Int(iPadCG.origin.y)))"
            + " 大きさ \(Int(iPadCG.width))x\(Int(iPadCG.height))")
        say("窓の予定地(AppKit座標に変換): 原点(\(Int(f.origin.x)),\(Int(f.origin.y)))"
            + " 大きさ \(Int(f.width))x\(Int(f.height)) 倍率\(scale)")

        // ★screen: は渡さない。渡すと座標が二重にズレる。
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: f.size),
                           styleMask: .borderless,
                           backing: .buffered,
                           defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = true          // マウスは素通り（操作は仮想側でやる）
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

        // ★真っ透明のまま置く。位置が正しいと確認できるまで 何も見せない。
        win.alphaValue = 0.0
        win.setFrame(f, display: false)
        win.orderFrontRegardless()

        // ---- 3.5 関所: WindowServer に実際の位置を聞いて、合っていなければ即撤収 ----
        //  登録が済むまで少し待つ。最大2秒、20回まで聞き直す。
        var realOpt: CGRect?
        for attempt in 1...20 {
            if let r = Self.realBounds(of: win) {
                realOpt = r
                if attempt > 1 { say("　（\(attempt)回目で確認できました）") }
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        guard let real = realOpt else {
            say("❌ 中止: 窓の実際の位置を確認できませんでした（窓番号=\(win.windowNumber)）。映しません。")
            win.orderOut(nil)
            exit(5)
        }
        say("窓の実際の位置(WindowServerに確認): 原点(\(Int(real.origin.x)),\(Int(real.origin.y)))"
            + " 大きさ \(Int(real.width))x\(Int(real.height))")

        let ok = abs(real.origin.x - iPadCG.origin.x) < 2
              && abs(real.origin.y - iPadCG.origin.y) < 2
              && abs(real.width  - iPadCG.width)  < 2
              && abs(real.height - iPadCG.height) < 2
        if !ok {
            say("")
            say("❌ 中止: 窓が iPad(ID=\(target.id)) の上に乗りませんでした。")
            say("　 狙い: 原点(\(Int(iPadCG.origin.x)),\(Int(iPadCG.origin.y)))"
                + " \(Int(iPadCG.width))x\(Int(iPadCG.height))")
            say("　 実際: 原点(\(Int(real.origin.x)),\(Int(real.origin.y)))"
                + " \(Int(real.width))x\(Int(real.height))")
            say("　 透明のまま撤収します。画面には何も出していません。")
            win.orderOut(nil)
            exit(5)
        }
        if CGDisplayIsBuiltin(target.id) != 0 || CGDisplayIsMain(target.id) != 0 {
            // ★2026-08-18 v3.7で追加: findTarget()側の穴を塞いだ上での
            //   最後の砦。ここでも「相手がメイン画面（＝内蔵画面が無いMacで
            //   操作中のモニタ）」なら必ず撤収する（6章【B】）。
            say("❌ 中止: 相手が本体内蔵ディスプレイ、またはメイン（操作中の）ディスプレイになっています。映しません。")
            win.orderOut(nil)
            exit(5)
        }
        say("✅ 関所通過: 窓は iPad の上に正しく乗りました。ここで初めて見えるようにします。")
        win.alphaValue = 1.0

        let host = NSView(frame: NSRect(origin: .zero, size: f.size))
        host.wantsLayer = true
        let base = CALayer()
        base.backgroundColor = NSColor.black.cgColor
        base.frame = CGRect(origin: .zero, size: f.size)
        host.layer = base

        // 傾ける板。倒す前は 810x1080（縦長）。90度倒すと 1080x810 にぴったり収まる。
        let video = CALayer()
        video.bounds = CGRect(x: 0, y: 0, width: CGFloat(vw), height: CGFloat(vh))
        video.position = CGPoint(x: f.width / 2, y: f.height / 2)
        video.contentsGravity = .resize
        video.contentsScale = scale
        video.magnificationFilter = .linear
        video.minificationFilter = .linear
        video.backgroundColor = NSColor.black.cgColor
        video.transform = CATransform3DMakeRotation(clockwise ? -.pi / 2 : .pi / 2, 0, 0, 1)
        base.addSublayer(video)

        win.contentView = host
        window = win
        say("窓を置きました（傾き: \(clockwise ? "時計回り" : "反時計回り")）")

        // ---- 安全装置: 決めた秒数で必ず自分から終わる ----
        if limitSeconds > 0 {
            say("★ 安全のため \(limitSeconds) 秒で自動的に終了します。")
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(limitSeconds)) {
                say("時間切れ。自動終了します。")
                globalRunner?.stop()
                exit(0)
            }
        }

        // ---- 3.9 ★v3.2★ 落ち着いたころに 見張りを始める ----
        //  すぐ始めると、自分でやった並べ替えの余波を拾って
        //  誤って撤収してしまう。2.5秒だけ待つ。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !kururinBailedOut else { return }
            self.armWatchdog(padID: target.id, virtualID: virtualID, want: iPadCG)
        }

        // ---- 4. 仮想ディスプレイの中身をキャプチャして流し込む ----
        let recv = FrameReceiver(layer: video)
        receiver = recv
        beginCapture(virtualID: virtualID,
                     pixelWidth: pixelW,
                     pixelHeight: pixelH,
                     fps: target.refreshRate,
                     receiver: recv)
    }

    private func nsScreen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == id }
    }

    private func beginCapture(virtualID: CGDirectDisplayID,
                              pixelWidth: Int, pixelHeight: Int,
                              fps: Double, receiver: FrameReceiver) {

        if !CGPreflightScreenCaptureAccess() {
            // ★v3.2★ ここでは 許可を求めない（CGRequestScreenCaptureAccess を呼ばない）。
            //  中身と皮の両方が呼ぶと、窓が2枚 重なって出ていた。
            //  許可の案内は 皮（くるりんパッ本体）が 1つだけ 出す。
            say("")
            say("⚠️ 画面収録の許可がありません。映像は届きません。")
        }

        Task { @MainActor in
            do {
                // 生まれたての仮想ディスプレイは一覧に出るまで少し遅れる
                var scDisplay: SCDisplay?
                for attempt in 1...20 {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: false)
                    if let d = content.displays.first(where: { $0.displayID == virtualID }) {
                        scDisplay = d
                        say("キャプチャ対象を見つけました（\(attempt)回目）: ID=\(virtualID)")
                        break
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                guard let scDisplay else {
                    say("❌ キャプチャ対象(ID=\(virtualID))が一覧に出てきませんでした")
                    say("　 画面収録の許可が無いと、この一覧は空になります。")
                    return
                }

                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width  = pixelWidth
                cfg.height = pixelHeight
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.showsCursor = true
                cfg.queueDepth = 5
                cfg.scalesToFit = false
                cfg.minimumFrameInterval = CMTime(value: 1,
                                                  timescale: CMTimeScale(max(30, Int(fps))))

                let s = SCStream(filter: filter, configuration: cfg, delegate: receiver)
                try s.addStreamOutput(receiver, type: .screen,
                                      sampleHandlerQueue: DispatchQueue(label: "kururin.frames"))
                try await s.startCapture()
                self.stream = s
                say("キャプチャ開始: \(pixelWidth)x\(pixelHeight) / 最大\(Int(fps))fps")
                say("")
                say("──────────────────────────────────────")
                say(" 動作中。止めるには ターミナルで Control + C")
                say("──────────────────────────────────────")

                // ★v3.8★ 6章【C】対応: キャプチャ開始が成功しても、
                //   実際には1コマも映像が来ないまま止まる事故があった
                //   （黒い窓が残ったまま無反応になる）。
                //   10秒待って それでも1コマ目が来ていなければ撤収する。
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak receiver] in
                    guard let receiver, !kururinBailedOut else { return }
                    if !receiver.reportedFirstFrame {
                        kururinBailOut("10秒待っても映像が1コマも届きません")
                    }
                }
            } catch {
                say("❌ キャプチャを始められません: \(error)")
                say("　 画面収録の許可（システム設定→プライバシーとセキュリティ→画面収録）")
                say("　 で「ターミナル」がオンになっているか確認してください。")
            }
        }
    }

    func stop() {
        if let s = stream {
            Task { try? await s.stopCapture() }
        }
        window?.orderOut(nil)
        window = nil
        virtualObject = nil
        say("片付けました")
    }
}


// MARK: - 入口

/// signal ハンドラからは変数を1個しか触れないので、ここに置いておく
var globalRunner: KururinRunner?


// ============================================================
//  ★張り付き対策（v3.2 で追加）★
//
//  なぜ要るか:
//   Sidecar が外れる / ディスプレイ設定を変えると、
//   macOS が画面の並びを組み直す。
//   すると iPad の上に置いた「最前面・枠なし・真っ黒」の窓が
//   本体画面の上に移動してしまい、メニューバーごと覆われて
//   何も見えない・押せない状態になる。
//
//  対策は3段構え（4段目の「命綱」は 皮の側にある）:
//   ① 画面の構成が変わった通知を受け取ったら 即撤収
//   ② 映像が止まったら 即撤収
//   ③ 0.5秒ごとに 窓の実位置を WindowServer に聞いて、
//      1ドットでもズレていたら 即撤収
//
//  撤収 = 窓を消す → 片付ける → プロセスを終わる（終了コード 6）。
//  皮はデーモンの終了を見て、メニューを「横（そのまま）」に戻す。
// ============================================================

/// 見張りを始めてよいか。窓が正しく乗って落ち着いてから true にする。
var kururinArmed = false
/// 二重に撤収しないための鍵
var kururinBailedOut = false
/// 窓と iPad が「ここに在るはず」という位置（CG座標）
var kururinWantRect = CGRect.zero
var kururinPadID: CGDirectDisplayID = 0
var kururinVirtualID: CGDirectDisplayID = 0

/// 生きている印を書き出す先。皮がこれを見て「固まっていないか」を判断する。
let kururinHeartbeatPath = "/tmp/kururin_pa.heartbeat"
var kururinHeartbeatTimer: Timer?

func kururinBeat() {
    // ★v3.8★ 6章【D】対応: 皮（親プロセス）が強制終了されると、
    //   このデーモンは孤児プロセスになり、育ての親のPIDが launchd(=1)
    //   に変わる。心臓は動き続けてしまう（heartbeatファイルを自分で
    //   書き続けるので、皮がいなくても命綱は誤爆しない）ため、
    //   デーモン自身が「親がいなくなったこと」に気づいて撤収する。
    if getppid() == 1 {
        kururinBailOut("皮が居なくなりました")
        return
    }
    try? String(Date().timeIntervalSince1970)
        .write(toFile: kururinHeartbeatPath, atomically: true, encoding: .utf8)
}

func kururinStartHeartbeat() {
    kururinBeat()
    let t = Timer(timeInterval: 1.0, repeats: true) { _ in kururinBeat() }
    RunLoop.main.add(t, forMode: .common)
    kururinHeartbeatTimer = t
}

/// ★どこから呼ばれても 必ず1回だけ、最短で窓を消して終わる★
func kururinBailOut(_ reason: String) {
    if kururinBailedOut { return }
    kururinBailedOut = true
    kururinArmed = false
    say("")
    say("🚑 自動撤収: \(reason)")

    // 保険。メインスレッドが固まっていても 2秒後には必ず落ちる。
    // プロセスが死ねば窓も消えるので、これが最後の逃げ道になる。
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
        say("　 （保険が働きました。強制終了します）")
        exit(6)
    }

    let finish = {
        globalRunner?.hideRightNow()
        globalRunner?.stop()
        say("　 撤収しました。メニューは「横（そのまま）」に戻ります。")
        exit(6)
    }
    if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
}

/// ① 画面の構成が変わったときに macOS が呼んでくれる関数
func kururinDisplayChanged(_ display: CGDirectDisplayID,
                           _ flags: CGDisplayChangeSummaryFlags,
                           _ userInfo: UnsafeMutableRawPointer?) {
    guard kururinArmed else { return }
    // 「これから変えます」の予告は無視する。本番の通知がこのあと来る。
    if flags.contains(.beginConfigurationFlag) { return }

    var what: [String] = []
    if flags.contains(.addFlag)                 { what.append("画面が増えた") }
    if flags.contains(.removeFlag)              { what.append("画面が減った") }
    if flags.contains(.movedFlag)               { what.append("画面が動いた") }
    if flags.contains(.setModeFlag)             { what.append("解像度が変わった") }
    if flags.contains(.disabledFlag)            { what.append("画面が切られた") }
    if flags.contains(.enabledFlag)             { what.append("画面が入った") }
    if flags.contains(.desktopShapeChangedFlag) { what.append("並びが変わった") }
    if what.isEmpty { return }

    kururinBailOut("画面の構成が変わりました（\(what.joined(separator: "・"))）")
}

func main() {
    let args = CommandLine.arguments
    var rotation: UInt32 = 0
    var modeName = "landscape"

    if args.count >= 2 {
        modeName = args[1]
        if args[1] == "portrait" { rotation = 1 }   // 暫定。調査結果が出たら確定させる
    }
    if args.count >= 3, let r = UInt32(args[2]) { rotation = r }

    say("たてモニ デーモン v3.8 開始（\(modeName) / 回転 \(rotation)）")
    say("ログ: \(logger.path)")

    // ---- 見るだけモード ----
    //  仮想ディスプレイも窓も一切作らない。今の状態を記録して終わるだけ。
    //  絶対に画面を壊さない。
    if modeName == "look" {
        say("")
        say("======== いまの画面の状態 ========")

        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &list, &count) == .success {
            say("CoreGraphics から見える画面: \(count) 台")
            for i in 0..<Int(count) {
                let id = list[i]
                let b = CGDisplayBounds(id)
                let mode = CGDisplayCopyDisplayMode(id)
                let px = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
                let pt = mode.map { "\($0.width)x\($0.height)" } ?? "?"
                let mirrorOf = CGDisplayMirrorsDisplay(id)
                let shape = b.height > b.width ? "縦長 ★" : "横長"
                say("")
                say("  ID=\(id)")
                say("    位置      : (\(Int(b.origin.x)), \(Int(b.origin.y)))")
                say("    見かけ    : \(Int(b.width))x\(Int(b.height))  → \(shape)")
                say("    モード上の見かけ : \(pt)")
                say("    モード上の実ピクセル: \(px)")
                say("    本体内蔵  : \(CGDisplayIsBuiltin(id) != 0)")
                say("    メイン    : \(CGDisplayIsMain(id) != 0)")
                say("    回転角    : \(CGDisplayRotation(id)) 度")
                say("    ミラー元  : \(mirrorOf == 0 ? "なし" : String(mirrorOf))")
                say("    使用中の解像度候補:")
                if let all = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] {
                    let uniq = Set(all.map { "\($0.width)x\($0.height)" }).sorted()
                    say("      \(uniq.joined(separator: ", "))")
                }
            }
        }

        say("")
        say("AppKit から見える画面: \(NSScreen.screens.count) 台")
        for s in NSScreen.screens {
            say("  ID=\(KururinRunner.displayID(of: s).map(String.init) ?? "?")"
                + "  位置(\(Int(s.frame.origin.x)),\(Int(s.frame.origin.y)))"
                + "  大きさ \(Int(s.frame.width))x\(Int(s.frame.height))"
                + "  倍率\(s.backingScaleFactor)")
        }
        say("")
        say("画面収録の許可: \(CGPreflightScreenCaptureAccess() ? "あり" : "なし")")
        say("======== ここまで ========")
        exit(0)
    }

    let manager = DaemonDisplayManager.shared

    guard let target = manager.findTarget() else {
        say("中止: 先に iPad を Sidecar でつないでください")
        exit(2)
    }

    if modeName == "probe" {
        manager.probeRotation(target: target)
        say("調査モード終了")
        exit(0)
    }

    // ---- 縦長の器を作れるか確かめるモード ----
    //  ミラーリングは しない。回転も しない（rotation=0）。
    //  ただ「810x1080 の縦長の画面」が生まれるかどうかだけを見る。
    if modeName == "tate" {
        let tate = target.swapped
        say("")
        say("======== 縦の器テスト ここから ========")
        say("iPad の見かけ      : \(target.pointWidth)x\(target.pointHeight)（横長）")
        say("これから作る器      : \(tate.pointWidth)x\(tate.pointHeight)（縦長）")
        say("実ピクセル(hiDPI2倍): \(tate.pixelWidth)x\(tate.pixelHeight)")
        say("")

        guard let built = manager.buildDisplay(target: tate, rotation: 0,
                                               name: "たてモニ縦") else {
            say("結果: ❌ 縦長の器を作れませんでした")
            say("======== 縦の器テスト ここまで ========")
            exit(1)
        }

        let w = Int(built.bounds.width), h = Int(built.bounds.height)
        say("できた画面: ID=\(built.id)  形=\(w)x\(h)")
        if w == tate.pointWidth && h == tate.pointHeight {
            say("結果: ⭕️ 成功。狙いどおり縦長の器ができました。")
        } else if w == tate.pointHeight && h == tate.pointWidth {
            say("結果: ❌ 横長になってしまいました（縦横が入れ替わっている）")
        } else {
            say("結果: ⚠️ 予想外の形です")
        }

        // 全画面の並びを記録（あとで配置を考えるときに使う）
        var list = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(16, &list, &count) == .success {
            say("")
            say("いま繋がっている画面 \(count) 台:")
            for i in 0..<Int(count) {
                let b = CGDisplayBounds(list[i])
                say("  ID=\(list[i])  位置(\(Int(b.origin.x)),\(Int(b.origin.y)))  大きさ \(Int(b.width))x\(Int(b.height))")
            }
        }
        say("======== 縦の器テスト ここまで ========")
        say("")
        say("★ この画面は 60秒間 だけ生きています。")
        say("★ アップルメニュー → システム設定 → ディスプレイ を開いて")
        say("★ 「たてモニ縦」という縦長の画面があるか見てください。")

        for remain in stride(from: 60, through: 5, by: -5) {
            say("  あと \(remain) 秒")
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 5.0))
        }
        say("縦の器テスト終了。画面を片付けます。")
        _ = built
        exit(0)
    }

    // ---- 本番モード ----
    if modeName == "run" {
        // 傾ける向き。args[2] が "ccw" なら反時計回り、それ以外は時計回り。
        let clockwise = !(args.count >= 3 && args[2].lowercased() == "ccw")
        // 安全装置の秒数。args[3]。既定は30秒。0 を渡すと止めるまで動き続ける。
        let limitSeconds = (args.count >= 4 ? Int(args[3]) : nil) ?? 30
        // マウスの入り口。args[4]。right / left / up / down。既定は right（実証済みの配置）。
        let entry = (args.count >= 5 ? args[4].lowercased() : "right")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dockにアイコンを出さない
        app.finishLaunching()                 // ★これを呼ばないとAppKitが画面の変化に気づかない

        let runner = KururinRunner()
        globalRunner = runner

        signal(SIGINT)  { _ in globalRunner?.stop(); exit(0) }
        signal(SIGTERM) { _ in globalRunner?.stop(); exit(0) }

        // ★v3.2★ ① 画面の構成が変わったら教えてもらう
        _ = CGDisplayRegisterReconfigurationCallback(kururinDisplayChanged, nil)
        // ★v3.2★ ④ 皮に「生きてます」と伝え続ける（1秒ごと）
        kururinStartHeartbeat()

        runner.start(clockwise: clockwise, limitSeconds: limitSeconds, entry: entry)
        app.run()
        exit(0)
    }

    guard let displayID = manager.setupVirtualDisplay(target: target, rotation: rotation) else {
        say("中止: 仮想ディスプレイを用意できませんでした")
        exit(1)
    }

    signal(SIGINT)  { _ in DaemonDisplayManager.shared.cleanup(); exit(0) }
    signal(SIGTERM) { _ in DaemonDisplayManager.shared.cleanup(); exit(0) }

    var mirrored = false
    for attempt in 1...12 {
        if manager.applyMirroring(targetID: target.id) {
            mirrored = true
            say("ミラーリング成功（\(attempt)回目） 仮想=\(displayID) → iPad=\(target.id)")
            let vb = CGDisplayBounds(displayID), tb = CGDisplayBounds(target.id)
            say("  ミラー後  仮想=\(Int(vb.width))x\(Int(vb.height))  iPad=\(Int(tb.width))x\(Int(tb.height))")
            say("  iPadがミラーしている相手=\(CGDisplayMirrorsDisplay(target.id))（\(displayID) なら成功）")
            break
        }
        say("ミラーリング再試行 \(attempt)/12")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
    }

    if !mirrored {
        say("中止: ミラーリングできませんでした")
        manager.cleanup()
        exit(3)
    }

    say("動作中。このプロセスが生きている間だけ画面が有効です。")
    while true {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
    }
}

main()
