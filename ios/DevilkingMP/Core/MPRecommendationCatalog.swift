import Foundation
import CoreFoundation

struct MPRecommendationSource {
    var id:String
    var title:String
    var category:MPBrowseCategory
    var mediaSource:String
    var defaultType:String
    var path:String?
    var query:[String:String] = [:]
    var selectionKeys:[String] = []
}

enum MPRecommendationCatalog {
    // Built-in order, translated selection keys and API paths are from MP's
    // current recommendation page. The MP user configuration supplies visibility.
    static let builtins:[MPRecommendationSource] = [
        MPRecommendationSource(id:"recommend/tmdb_trending",title:"流行趋势",category:.all,mediaSource:"themoviedb",defaultType:"",path:"/api/v1/recommend/tmdb_trending",query:[:],selectionKeys:["流行趋势", "流行趨勢", "Trending Now"]),
        MPRecommendationSource(id:"recommend/douban_showing",title:"正在热映",category:.movie,mediaSource:"douban",defaultType:"电影",path:"/api/v1/recommend/douban_showing",query:[:],selectionKeys:["正在热映", "正在熱映", "Now Showing"]),
        MPRecommendationSource(id:"recommend/bangumi_calendar",title:"Bangumi每日放送",category:.anime,mediaSource:"bangumi",defaultType:"电视剧",path:"/api/v1/recommend/bangumi_calendar",query:[:],selectionKeys:["Bangumi每日放送", "Bangumi Daily Release"]),
        MPRecommendationSource(id:"anilist/trending",title:"AniList 当前趋势",category:.anime,mediaSource:"anilist",defaultType:"电视剧",path:"/api/v1/anilist/trending",query:[:],selectionKeys:["AniList 当前趋势", "AniList 當前趨勢", "AniList TRENDING NOW"]),
        MPRecommendationSource(id:"anilist/popular-this-season",title:"AniList 本季热门",category:.anime,mediaSource:"anilist",defaultType:"电视剧",path:"/api/v1/anilist/popular-this-season",query:[:],selectionKeys:["AniList 本季热门", "AniList 本季熱門", "AniList POPULAR THIS SEASON"]),
        MPRecommendationSource(id:"recommend/tmdb_movies",title:"TMDB热门电影",category:.movie,mediaSource:"themoviedb",defaultType:"电影",path:"/api/v1/recommend/tmdb_movies",query:[:],selectionKeys:["TMDB热门电影", "TMDB熱門電影", "TMDB Hot Movies"]),
        MPRecommendationSource(id:"recommend/tmdb_tvs",title:"TMDB热门电视剧",category:.tv,mediaSource:"themoviedb",defaultType:"电视剧",path:"/api/v1/recommend/tmdb_tvs",query:["with_original_language":"zh|en|ja|ko"],selectionKeys:["TMDB热门电视剧", "TMDB熱門電視劇", "TMDB Hot TV Shows"]),
        MPRecommendationSource(id:"recommend/douban_movie_hot",title:"豆瓣热门电影",category:.movie,mediaSource:"douban",defaultType:"电影",path:"/api/v1/recommend/douban_movie_hot",query:[:],selectionKeys:["豆瓣热门电影", "豆瓣熱門電影", "Douban Hot Movies"]),
        MPRecommendationSource(id:"recommend/douban_tv_hot",title:"豆瓣热门电视剧",category:.tv,mediaSource:"douban",defaultType:"电视剧",path:"/api/v1/recommend/douban_tv_hot",query:[:],selectionKeys:["豆瓣热门电视剧", "豆瓣熱門電視劇", "Douban Hot TV Shows"]),
        MPRecommendationSource(id:"recommend/douban_tv_animation",title:"豆瓣热门动漫",category:.anime,mediaSource:"douban",defaultType:"电视剧",path:"/api/v1/recommend/douban_tv_animation",query:[:],selectionKeys:["豆瓣热门动漫", "豆瓣熱門動漫", "Douban Hot Anime"]),
        MPRecommendationSource(id:"recommend/douban_movies",title:"豆瓣最新电影",category:.movie,mediaSource:"douban",defaultType:"电影",path:"/api/v1/recommend/douban_movies",query:[:],selectionKeys:["豆瓣最新电影", "豆瓣最新電影", "Douban New Movies"]),
        MPRecommendationSource(id:"recommend/douban_tvs",title:"豆瓣最新电视剧",category:.tv,mediaSource:"douban",defaultType:"电视剧",path:"/api/v1/recommend/douban_tvs",query:[:],selectionKeys:["豆瓣最新电视剧", "豆瓣最新電視劇", "Douban New TV Shows"]),
        MPRecommendationSource(id:"recommend/douban_movie_top250",title:"豆瓣电影TOP250",category:.movie,mediaSource:"douban",defaultType:"电影",path:"/api/v1/recommend/douban_movie_top250",query:[:],selectionKeys:["豆瓣电影TOP250", "豆瓣電影TOP250", "Douban Top 250 Movies"]),
        MPRecommendationSource(id:"recommend/douban_tv_weekly_chinese",title:"豆瓣国产剧集榜",category:.tv,mediaSource:"douban",defaultType:"电视剧",path:"/api/v1/recommend/douban_tv_weekly_chinese",query:[:],selectionKeys:["豆瓣国产剧集榜", "豆瓣國產劇集榜", "Douban Chinese TV Rankings"]),
        MPRecommendationSource(id:"recommend/douban_tv_weekly_global",title:"豆瓣全球剧集榜",category:.tv,mediaSource:"douban",defaultType:"电视剧",path:"/api/v1/recommend/douban_tv_weekly_global",query:[:],selectionKeys:["豆瓣全球剧集榜", "豆瓣全球劇集榜", "Douban Global TV Rankings"]),
    ]
    static func configured(_ configuration:[String:Any],extensions:[[String:Any]],providers:[[String:Any]]) throws -> [MPRecommendationSource] {
        guard configuration.keys.contains("value") else { throw AppError.message("MoviePilot 推荐栏目配置缺少值。") }
        let enabled:[String:Bool]?
        if configuration["value"] is NSNull { enabled=nil }
        else if let raw=configuration["value"] as? [String:Any],raw.values.allSatisfy({ bool($0) != nil }) { enabled=raw.mapValues{bool($0)!} }
        else { throw AppError.message("MoviePilot 推荐栏目配置格式不完整。") }
        let available=Set(providers.map{$0.str("media_source")})
        var result=[MPRecommendationSource]()
        for source in builtins where available.contains(source.mediaSource) {
            let flags=source.selectionKeys.compactMap{enabled?[$0]}
            // MP automatically enables its newly introduced AniList sources if
            // an older saved selection did not yet include these names.
            let selected=enabled == nil || flags.contains(true) || (flags.isEmpty && source.mediaSource == "anilist")
            if selected { result.append(source) }
        }
        for row in extensions.prefix(30) {
            let name=MPResourceParser.display(row.str("name")),rawPath=row.str("api_path")
            guard !name.isEmpty,enabled?[name] == true else { continue }
            let path=rawPath.hasPrefix("/api/v1/") ? rawPath:String("/api/v1/")+rawPath.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            if result.contains(where:{$0.path == path}) { continue }
            // Extension routes are arbitrary plugin code. Unknown GET routes
            // must not acquire credentials or execute merely because they appear in a catalog.
            if let known=builtins.first(where:{$0.path == path}) {
                var source=known;source.id="extension:"+MPResourceParser.digest(name+"\n"+path);source.title=name;source.selectionKeys=[name];result.append(source)
            } else {
                result.append(MPRecommendationSource(id:"extension:"+MPResourceParser.digest(name+"\n"+path),title:name,category:.all,mediaSource:"",defaultType:"",path:nil))
            }
        }
        return result
    }
    private static func bool(_ raw:Any)->Bool? {
        guard let value=raw as? NSNumber,CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}
