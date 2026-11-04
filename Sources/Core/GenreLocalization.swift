import Foundation

/// Normalize recognized genres before they enter the draft, so preview and saved tags agree.
/// Existing file tags and manual edits do not pass through this mapping.
enum GenreLocalization {
    static func localized(_ genres: [String], isChinese: Bool = L10n.isChinese) -> String {
        var seen = Set<String>()
        return genres.compactMap { raw -> String? in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let genre = namesByAlias[name.lowercased()]
            // Providers can return new or specialized genres; keep those intact.
            let localized = genre.map { isChinese ? $0.chinese : $0.english } ?? name
            return seen.insert(localized.lowercased()).inserted ? localized : nil
        }.joined(separator: "; ")
    }

    private struct Genre {
        let english: String
        let chinese: String
        let aliases: [String]

        init(_ english: String, _ chinese: String, aliases: [String] = []) {
            self.english = english
            self.chinese = chinese
            self.aliases = aliases
        }
    }

    private static let namesByAlias: [String: Genre] = {
        let genres: [Genre] = [
            Genre("Pop", "流行", aliases: ["国际流行", "國際流行", "流行音乐", "流行音樂"]),
            Genre("Mandopop", "国语流行", aliases: ["國語流行", "Mandarin Pop"]),
            Genre("Cantopop", "粤语流行", aliases: ["粵語流行", "Cantonese Pop"]),
            Genre("C-Pop", "华语流行", aliases: ["華語流行"]),
            Genre("J-Pop", "日本流行", aliases: ["日语流行", "日語流行"]),
            Genre("K-Pop", "韩国流行", aliases: ["韓國流行", "韩语流行", "韓語流行"]),
            Genre("Rock", "摇滚", aliases: ["搖滾"]),
            Genre("Alternative", "另类", aliases: ["另類"]),
            Genre("Indie Rock", "独立摇滚", aliases: ["獨立搖滾"]),
            Genre("Hard Rock", "硬摇滚", aliases: ["硬搖滾"]),
            Genre("Metal", "金属", aliases: ["金屬"]),
            Genre("Punk", "朋克", aliases: ["龐克"]),
            Genre("Jazz", "爵士"),
            Genre("Blues", "蓝调", aliases: ["藍調", "布鲁斯", "布魯斯"]),
            Genre("R&B/Soul", "R&B/灵魂乐", aliases: ["R&B／灵魂乐", "R&B/靈魂樂", "R&B／靈魂樂"]),
            Genre("R&B", "节奏布鲁斯", aliases: ["節奏藍調", "节奏蓝调", "Rhythm and Blues"]),
            Genre("Soul", "灵魂乐", aliases: ["靈魂樂"]),
            Genre("Hip-Hop/Rap", "嘻哈/说唱", aliases: ["Hip Hop/Rap", "嘻哈／说唱", "嘻哈/饒舌", "嘻哈／饒舌"]),
            Genre("Hip-Hop", "嘻哈", aliases: ["Hip Hop"]),
            Genre("Rap", "说唱", aliases: ["饶舌", "饒舌"]),
            Genre("Dance", "舞曲"),
            Genre("Electronic", "电子", aliases: ["電子", "电子音乐", "電子音樂"]),
            Genre("House", "浩室"),
            Genre("Techno", "铁克诺", aliases: ["鐵克諾"]),
            Genre("Ambient", "氛围音乐", aliases: ["氛圍音樂"]),
            Genre("Country", "乡村", aliases: ["鄉村"]),
            Genre("Folk", "民谣", aliases: ["民謠"]),
            Genre("Singer/Songwriter", "创作歌手", aliases: ["創作歌手", "唱作人"]),
            Genre("Classical", "古典", aliases: ["古典音乐", "古典音樂"]),
            Genre("Opera", "歌剧", aliases: ["歌劇"]),
            Genre("Easy Listening", "轻音乐", aliases: ["輕音樂"]),
            Genre("Instrumental", "器乐", aliases: ["器樂"]),
            Genre("New Age", "新世纪", aliases: ["新世紀"]),
            Genre("Reggae", "雷鬼"),
            Genre("Latin", "拉丁"),
            Genre("World", "世界音乐", aliases: ["世界音樂", "Worldwide", "World Music"]),
            Genre("Soundtrack", "原声音乐", aliases: ["原聲音樂", "原声带", "原聲帶", "Soundtracks"]),
            Genre("Anime", "动漫", aliases: ["動漫"]),
            Genre("Children's Music", "儿童音乐", aliases: ["兒童音樂", "Children’s Music"]),
            Genre("Christian & Gospel", "基督教与福音", aliases: ["基督教與福音"]),
            Genre("Holiday", "节日音乐", aliases: ["節日音樂"]),
            Genre("Christmas", "圣诞音乐", aliases: ["聖誕音樂"]),
            Genre("Fitness & Workout", "健身与运动", aliases: ["健身與運動"]),
            Genre("Comedy", "喜剧", aliases: ["喜劇"]),
            Genre("Music", "音乐", aliases: ["音樂"])
        ]
        var result: [String: Genre] = [:]
        for genre in genres {
            for name in [genre.english, genre.chinese] + genre.aliases {
                result[name.lowercased()] = genre
            }
        }
        return result
    }()
}
