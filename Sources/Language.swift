import Foundation

/// The desk's language: English, or Japanese. Chosen in settings and kept; the words are written in English
/// throughout, and `tr` gives them in Japanese when that's chosen (a word it doesn't know stays as it is).
enum Language: String, CaseIterable {
    case english = "en", japanese = "ja"

    static let key = "language"
    /// said in ReDesk when the language changes
    static let changed = Notification.Name("ReDeskLanguageChanged")

    static var current: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .english }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
            // the Re apps write their buttons in it too
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.artursavytskyi.re.language"), object: newValue.rawValue, userInfo: nil, deliverImmediately: true)
        }
    }

    static var isJapanese: Bool { current == .japanese }

    /// each in its own language
    var title: String {
        switch self {
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

/// The words in the chosen language.
func tr(_ words: String) -> String {
    guard Language.isJapanese else { return words }
    return japaneseWords[words] ?? words
}

private let japaneseWords: [String: String] = [
    // ── the corner words: four characters, as FILE, SURF… ──
    "FILE": "ファイル",
    "SURF": "ブラウザ",
    "DRAW": "お絵描き",
    "NOTE": "覚え書き",

    // ── settings ──
    "Desk": "デスク",
    "Language": "言語",
    "Tile windows": "ウィンドウを並べる",
    "Tiling needs Accessibility": "並べるにはアクセシビリティが必要",
    "Allow": "許可",
    "Arrangement": "配置",
    "Almost full": "ほぼ全画面",
    "Flush": "隙間なし",
    "Ink cursors": "墨のカーソル",
    "Dark appearance": "ダークモード",
    "Open at login": "ログイン時に開く",
    "Wallpaper": "壁紙",
    "Wallpaper from YouTube": "YouTubeの壁紙",
    "Add": "追加",
    "This wallpaper": "この壁紙",
    "Remove": "削除",
    "Blur wallpaper": "壁紙をぼかす",
    "Video wallpaper stands still": "動画の壁紙を止める",
    "Screen": "画面",
    "Lock screen": "画面をロック",
    "Lock": "ロック",
    "Snap or clap": "指パッチンか拍手",
    "Snap does": "指パッチンで",
    "Blow on the Mac": "Macに息を吹きかける",
    "Blowing does": "息で",
    "Brightness by lid": "蓋で明るさ",
    "Knocks": "ノック",
    "Knocks on the Mac": "Macをノック",
    "2 knocks": "2回ノック",
    "3 knocks": "3回ノック",
    "4 knocks": "4回ノック",
    "5 knocks": "5回ノック",
    "Sensitivity": "感度",
    "Firm": "強く",
    "Medium": "普通",
    "Light": "軽く",
    "On": "オン",
    "Off": "オフ",
    "Quit": "終了",
    "⌃⌥, settings  ·  ⌃⌥/ keys": "⌃⌥, 設定  ·  ⌃⌥/ キー",
    "looking": "検索中",

    // ── arrangements ──
    "Main and Stack": "メインと重ね",
    "Main on Top": "メインを上に",
    "Main in the Middle": "メインを中央に",
    "Columns": "列",
    "Rows": "行",
    "Grid": "格子",
    "One at a Time": "一つずつ",
    "Full Screen": "全画面",

    // ── what a knock, a snap, a breath does ──
    "Nothing": "なし",
    "Lock Screen": "画面をロック",
    "Play / Pause": "再生 / 一時停止",
    "Mute": "消音",
    "Screenshot": "スクリーンショット",
    "Hide / Show Windows": "ウィンドウを隠す / 表示",
    "Close All Windows": "すべてのウィンドウを閉じる",
    "Next Wallpaper": "次の壁紙",
    "Pause Wallpaper": "壁紙を止める",
    "Blur Wallpaper": "壁紙をぼかす",
    "Open ReFile": "ReFileを開く",
    "Open ReSurf": "ReSurfを開く",
    "Open ReDraw": "ReDrawを開く",
    "Open ReNote": "ReNoteを開く",

    // ── a wallpaper from YouTube ──
    "Paste a link: the video plays from YouTube in its best quality, without sound.":
        "リンクを貼り付けてください。動画はYouTubeから最高画質・無音で再生されます。",
    "Cancel": "キャンセル",
    "No wallpaper from YouTube": "YouTubeの壁紙を追加できません",
    "That isn't a YouTube link.": "YouTubeのリンクではありません。",
    "It takes yt-dlp: brew install yt-dlp": "yt-dlpが必要です：brew install yt-dlp",
    "YouTube didn't give the video.": "YouTubeから動画を取得できませんでした。",
    "It couldn't be kept.": "保存できませんでした。",

    // ── the lock screen ──
    "UNLOCK": "解除",

    // ── keys ──
    "⌃⌥/ or Esc closes  ·  ⌃⌥, settings": "⌃⌥/ か Esc で閉じる  ·  ⌃⌥, 設定",
    "Windows": "ウィンドウ",
    "On the desk": "デスクで",
    "Desktops": "デスクトップ",
    "In the Re apps": "Reアプリで",
    "On the Mac": "Macで",
    "Play": "再生",
    "View": "表示",
    "Search": "検索",
    "Notes": "ノート",
    "A note": "ノートの中",
    "Writing": "書く",
    "settings": "設定",
    "these keys": "このキー一覧",
    "lock screen": "画面をロック",
    "light / dark": "ライト / ダーク",
    "video wallpaper still / moving": "動画の壁紙を止める / 動かす",
    "focus the nearest window": "隣のウィンドウへ",
    "trade places with it": "隣と入れ替える",
    "resize the window": "ウィンドウの大きさを変える",
    "tiling on / off": "並べる オン / オフ",
    "next arrangement": "次の配置",
    "the window becomes the main one": "このウィンドウをメインに",
    "pin the window to its place": "ウィンドウをその場に固定",
    "ReFile / ReSurf / ReDraw / ReNote": "ReFile / ReSurf / ReDraw / ReNote",
    "the desktop above / below": "上 / 下のデスクトップ",
    "take the window there": "ウィンドウを連れて行く",
    "an arrangement": "配置を選ぶ",
    "almost full on / off": "ほぼ全画面 オン / オフ",
    "flush on / off": "隙間なし オン / オフ",
    "fill the screen / the desk": "画面 / デスクいっぱいに",
    "previous / next wallpaper": "前 / 次の壁紙",
    "2 – 5 knocks": "2 – 5回ノック",
    "as chosen in settings": "設定で選んだ通り",
    "snap or clap": "指パッチンか拍手",
    "file / text / view / play": "ファイル / テキスト / 表示 / 再生",
    "all inside": "中身をすべて",
    "new window": "新しいウィンドウ",
    "select": "選ぶ",
    "open": "開く",
    "the folder above": "上のフォルダ",
    "search": "検索",
    "views": "表示の切り替え",
    "sort: name, kind, date, size": "並び順：名前、種類、日付、サイズ",
    "new folder": "新しいフォルダ",
    "info": "情報",
    "move to the Trash": "ゴミ箱に入れる",
    "folder / songs / radio": "フォルダ / 曲 / ラジオ",
    "play / pause": "再生 / 一時停止",
    "shuffle / repeat": "シャッフル / リピート",
    "queue": "再生待ち",
    "keep a station": "局を保存",
    "mini player": "ミニプレーヤー",
    "turn the page": "ページをめくる",
    "manga": "漫画",
    "full screen": "全画面",
    "new tab": "新しいタブ",
    "address": "アドレス",
    "close tab": "タブを閉じる",
    "next tab": "次のタブ",
    "back / forward": "戻る / 進む",
    "reload": "再読み込み",
    "favourite": "お気に入り",
    "video fills the page": "動画をページいっぱいに",
    "e-ink": "電子ペーパー",
    "ReChat": "ReChat",
    "all / images / videos": "すべて / 画像 / 動画",
    "the same in Marginalia": "Marginaliaで同じ検索",
    "previous / next page": "前 / 次のページ",
    "choose, open": "選ぶ、開く",
    "send": "送信",
    "new line": "改行",
    "pen / brush / rubber": "ペン / 筆 / 消しゴム",
    "the trackpad as a tablet": "トラックパッドをタブレットに",
    "line": "線の太さ",
    "undo / redo": "取り消す / やり直す",
    "clear": "消去",
    "nearer / further": "拡大 / 縮小",
    "as it was": "元の大きさ",
    "save a PNG": "PNGで保存",
    "select a note": "ノートを選ぶ",
    "another space": "別のスペース",
    "new note": "新しいノート",
    "edit": "編集",
    "delete": "削除",
    "home": "ホーム",
    "save": "保存",
    "previous / next note": "前 / 次のノート",
    "back": "戻る",
    "highlight": "ハイライト",
    "undo": "取り消す",
    "redo": "やり直す",
]
