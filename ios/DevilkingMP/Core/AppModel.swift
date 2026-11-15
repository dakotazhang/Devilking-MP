import Foundation
import Combine
import LocalAuthentication

@MainActor final class AppModel: ObservableObject {
    @Published var profiles: [ServiceProfile]
    @Published var snapshots: [ServiceKind:ServiceSnapshot]=[:]
    @Published var tasks: [TorrentTask]=[]
    @Published var subscriptions: [Subscription]=[]
    @Published var dashboardSnapshots: [ServiceKind:DashboardSnapshot]=[:]
    @Published var dashboardRefreshing=false
    @Published var dashboardManualRefreshing=false
    @Published var discoverySections:[MPDiscoverySection]=[]
    @Published var discoveryResults:[MPDiscoveryItem]=[]
    @Published var discoveryLoading=false
    @Published var discoverySearchLoading=false
    @Published var discoveryError:String?
    @Published var discoveryQuery=""
    @Published var discoveryUpdatedAt:Date?
    @Published private(set) var mpArtworkRefreshToken=UUID()
    @Published var resourceDirectoryOptions:[MPResourceDirectory]=[]
    @Published var resourceDirectoriesLoading=false
    @Published var resourceDirectoriesError:String?
    @Published private(set) var resourceConnectionEpoch=UUID()
    @Published private(set) var interactionEpoch=UUID()
    @Published var sites: [SiteAccount]=[]
    @Published var library: [MediaItem]=[]
    @Published var searchResults: [MediaItem]=[]
    @Published var sessions: [PlaybackSession]=[]
    @Published var busy=false
    @Published var message: String?
    @Published var readOnlyMode:Bool { didSet { defaults.set(readOnlyMode,forKey:"readOnlyMode");generation &+= 1;interactionEpoch=UUID() } }
    @Published var migrationProtection: Bool { didSet { defaults.set(migrationProtection,forKey:"migrationProtection");generation &+= 1;interactionEpoch=UUID() } }
    @Published var biometricEnabled: Bool { didSet { defaults.set(biometricEnabled,forKey:"biometricEnabled") } }
    @Published var locked=false
    private let defaults:UserDefaults
    let preferences:AppPreferences
    private let credentialReader:(ServiceKind)->Credential
    private let clientFactory:(ServiceProfile,Credential)->APIClient
    private let readBudgetSeconds:TimeInterval
    private var clients:[ServiceKind:APIClient]=[:]
    private var inflight=Set<String>()
    private var refreshRunning=false
    private var actionInFlight=false
    private var generation=0
    private var discoverySearchGeneration=0
    private var dashboardJob:Task<Void,Never>?
    private var dashboardCycle:UUID?
    private var discoveryJob:Task<Void,Never>?
    private var discoveryCycle:UUID?
    #if DEBUG
    var uiFixtureMode=false
    #endif
    private let posterCache:NSCache<NSString,NSData> = {let c=NSCache<NSString,NSData>();c.countLimit=100;c.totalCostLimit=32*1024*1024;return c}()
    private let mpArtworkCache:NSCache<NSString,NSData> = {let c=NSCache<NSString,NSData>();c.countLimit=80;c.totalCostLimit=16*1024*1024;return c}()
    private let mpArtworkGate=MPArtworkReadGate(limit:4)
    private var mpArtworkJobs:[String:(UUID,Task<Data?,Never>)]=[:]
    init(defaults:UserDefaults = .standard, credentialReader:@escaping (ServiceKind)->Credential = { KeychainStore.read($0) }, clientFactory:@escaping (ServiceProfile,Credential)->APIClient = { APIClient(profile:$0,credentials:$1) }, readBudgetSeconds:TimeInterval = 22) {
        #if DEBUG
        let defaults = ProcessInfo.processInfo.arguments.contains("--ui-fixture") ? UserDefaults(suiteName:"DevilkingMP-UITestFixture")! : defaults
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { defaults.removePersistentDomain(forName:"DevilkingMP-UITestFixture") }
        #endif
        self.defaults=defaults
        preferences=AppPreferences(defaults:defaults)
        self.credentialReader=credentialReader
        self.clientFactory=clientFactory
        self.readBudgetSeconds=readBudgetSeconds
        profiles=(defaults.data(forKey:"profiles").flatMap{try? JSONDecoder().decode([ServiceProfile].self,from:$0)}) ?? ServiceKind.allCases.map{ServiceProfile(kind:$0,baseURL:$0.defaultURL,username:"")}
        migrationProtection=defaults.object(forKey:"migrationProtection") == nil ? true:defaults.bool(forKey:"migrationProtection")
        readOnlyMode=defaults.object(forKey:"readOnlyMode") == nil ? true:defaults.bool(forKey:"readOnlyMode")
        biometricEnabled=defaults.bool(forKey:"biometricEnabled");locked=biometricEnabled
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-fixture") { UITestFixtures.apply(to:self) }
        #endif
    }
    func profile(_ kind:ServiceKind)->ServiceProfile { profiles.first{$0.kind == kind} ?? ServiceProfile(kind:kind,baseURL:kind.defaultURL,username:"") }
    func credential(_ kind:ServiceKind)->Credential { credentialReader(kind) }
    func isConfigured(_ kind:ServiceKind)->Bool {
        #if DEBUG
        if uiFixtureMode { return kind != .emby }
        #endif
        return !credential(kind).isEmpty
    }
    func canManage(_ kind:ServiceKind)->Bool { !readOnlyMode && !locked && profile(kind).allowActions && isConfigured(kind) && !([ServiceKind.qb1,.tr].contains(kind) && migrationProtection) }
    private func persist() { if let data=try? JSONEncoder().encode(profiles) { defaults.set(data,forKey:"profiles") } }
    func saveConnection(_ kind:ServiceKind,baseURL:String,username:String,password:String,apiKey:String,allowActions:Bool) throws {
        generation &+= 1
        interactionEpoch=UUID()
        let url=try EndpointPolicy.validate(baseURL)
        if kind.isDownloader {
            let proposed=url.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
            guard !profiles.contains(where:{$0.kind != kind && $0.kind.isDownloader && $0.baseURL.trimmingCharacters(in:CharacterSet(charactersIn:"/")) == proposed}) else{throw AppError.message("两个下载器不能指向同一入口，以免绕过角色和迁移保护。")}
        }
        guard !password.isEmpty || !apiKey.isEmpty else { throw AppError.message("请填写密码或 API Key。") }
        if apiKey.isEmpty && username.isEmpty { throw AppError.message("请输入用户名。") }
        try KeychainStore.write(Credential(username:username,password:password,apiKey:apiKey),kind:kind)
        if kind == .moviepilot { resourceConnectionEpoch=UUID() }
        resetReadJobs()
        if kind == .moviepilot || kind.isDownloader { preferences.clearResourcePreferences(for:profile(.moviepilot).baseURL) }
        let p=ServiceProfile(kind:kind,baseURL:url.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/")),username:username,allowActions:allowActions)
        if let i=profiles.firstIndex(where:{$0.kind == kind}) { profiles[i]=p } else { profiles.append(p) }
        clients[kind]=nil;snapshots[kind]=nil;dashboardSnapshots[kind]=nil;tasks.removeAll{$0.kind == kind}
        if kind == .moviepilot{subscriptions=[];sites=[];searchResults=[];discoverySections=[];discoveryResults=[];discoveryError=nil;discoveryUpdatedAt=nil;resourceDirectoryOptions=[];resourceDirectoriesError=nil}
        if kind == .emby{library=[];sessions=[]};persist()
        if kind == .emby{posterCache.removeAllObjects()}
    }
    func disconnect(_ kind:ServiceKind) {
        generation &+= 1
        interactionEpoch=UUID()
        if kind == .moviepilot { resourceConnectionEpoch=UUID() }
        resetReadJobs()
        if kind == .moviepilot || kind.isDownloader { preferences.clearResourcePreferences(for:profile(.moviepilot).baseURL) }
        KeychainStore.delete(kind);clients[kind]=nil;snapshots[kind]=nil;dashboardSnapshots[kind]=nil
        tasks.removeAll{$0.kind == kind}
        if kind == .moviepilot { subscriptions=[];sites=[];searchResults=[];discoverySections=[];discoveryResults=[];discoveryError=nil;discoveryUpdatedAt=nil;resourceDirectoryOptions=[];resourceDirectoriesError=nil }
        if kind == .emby { library=[];sessions=[] }
        if kind == .emby{posterCache.removeAllObjects()}
        if let i=profiles.firstIndex(where:{$0.kind == kind}) { profiles[i].allowActions=false;profiles[i].username="" };persist()
    }
    private func client(_ kind:ServiceKind) throws -> APIClient {
        #if DEBUG
        guard !uiFixtureMode else { throw AppError.message("界面测试样本不会连接网络。") }
        #endif
        guard !locked else { throw AppError.message("请先解锁应用。") }
        guard isConfigured(kind) else { throw AppError.message("请先连接 \(kind.title)。") }
        if let c=clients[kind] { return c }
        let c=clientFactory(profile(kind),credential(kind));clients[kind]=c;return c
    }
    static func safeError(_ error:Error)->String {
        if let e=error as? AppError { return e.localizedDescription }
        if let u=error as? URLError {
            switch u.code { case .timedOut:return "连接超时。外出请先接通家庭 WireGuard。";case .notConnectedToInternet,.cannotConnectToHost,.cannotFindHost,.networkConnectionLost:return "无法连接服务。请检查家庭 Wi‑Fi 或 WireGuard。";case .cancelled:return "请求已取消。";case .serverCertificateUntrusted,.secureConnectionFailed:return "HTTPS 证书校验失败，请使用有效证书。";default:return "网络请求失败（\(u.code.rawValue)），未自动重试。" }
        };return "请求未完成，未自动重试。请到原管理页核对状态。"
    }
    func refreshAll() async {
        guard !locked && !refreshRunning else { return };refreshRunning=true;defer{refreshRunning=false}
        await refreshDashboard()
        if isConfigured(.moviepilot) { await refresh(.moviepilot) }
    }
    func refreshDashboard(manual:Bool = true) async {
        guard !locked && !Task.isCancelled else{return}
        if let job=dashboardJob {
            if manual { dashboardManualRefreshing=true }
            await job.value
            return
        }
        let cycle=UUID()
        dashboardCycle=cycle;dashboardRefreshing=true;dashboardManualRefreshing=manual
        let job=Task { @MainActor [weak self] in
            guard let self else{return}
            defer {
                if self.dashboardCycle == cycle {
                    self.dashboardRefreshing=false;self.dashboardManualRefreshing=false
                    self.dashboardJob=nil;self.dashboardCycle=nil
                }
            }
            #if DEBUG
            if self.uiFixtureMode { self.dashboardSnapshots=UITestFixtures.dashboard();return }
            #endif
            await withTaskGroup(of:Void.self) { group in
                for kind in ServiceKind.allCases where kind.isDownloader && self.isConfigured(kind) {
                    group.addTask { await self.refreshDashboardService(kind) }
                }
            }
        }
        dashboardJob=job
        await withTaskCancellationHandler(operation:{ await job.value },onCancel:{ job.cancel() })
    }
    private func refreshDashboardService(_ kind:ServiceKind) async {
        let g=generation
        do {
            let api=try client(kind)
            let value=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.dashboard() }
            guard g == generation && !locked else{return}
            dashboardSnapshots[kind]=value
            snapshots[kind]=ServiceSnapshot(kind:kind,online:true,detail:kind.subtitle,downloadRate:value.downloadRate ?? 0,uploadRate:value.uploadRate ?? 0,taskCount:value.counts?.total)
        } catch {
            guard g == generation && !locked else{return}
            guard !Task.isCancelled && !(error is CancellationError) else{return}
            clients[kind]=nil
            dashboardSnapshots[kind]=DashboardSnapshot.failure(kind:kind,previous:dashboardSnapshots[kind],error:Self.safeError(error))
            snapshots[kind]=ServiceSnapshot(kind:kind,online:false,detail:"连接未确认",error:Self.safeError(error))
        }
    }
    func refresh(_ kind:ServiceKind) async {
        #if DEBUG
        if uiFixtureMode { snapshots=UITestFixtures.snapshots();return }
        #endif
        let key="snapshot-"+kind.rawValue;guard !locked && !inflight.contains(key) && isConfigured(kind) else{return}
        inflight.insert(key);defer{inflight.remove(key)}
        let g=generation
        do { let s=try await client(kind).snapshot();guard g == generation && !locked else{return};snapshots[kind]=s }
        catch {guard g == generation && !locked else{return};clients[kind]=nil;snapshots[kind]=ServiceSnapshot(kind:kind,online:false,detail:"连接未确认",error:Self.safeError(error)) }
    }
    @discardableResult func loadTasks(_ kind:ServiceKind) async -> Bool {
        guard kind.isDownloader else { return false }
        #if DEBUG
        if uiFixtureMode { tasks.removeAll{$0.kind == kind};tasks.append(contentsOf:UITestFixtures.tasks(kind));return true }
        #endif
        let key="tasks-"+kind.rawValue;guard !locked && !inflight.contains(key) else{return false};inflight.insert(key);busy=true;defer{inflight.remove(key);busy = !inflight.isEmpty};let g=generation
        do {
            let api=try client(kind)
            let rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.tasks() }
            guard g == generation && !locked && !Task.isCancelled else{return false};tasks.removeAll{$0.kind == kind};tasks.append(contentsOf:rows)
            if var s=snapshots[kind] { s.taskCount=rows.count;s.updatedAt=Date();snapshots[kind]=s }
            return true
        } catch {if g == generation{clients[kind]=nil;message=Self.safeError(error)};return false}
    }
    @discardableResult func loadMoviePilot() async -> Bool {
        #if DEBUG
        if uiFixtureMode { subscriptions=UITestFixtures.subscriptions();sites=UITestFixtures.sites();return true }
        #endif
        guard !locked && !inflight.contains("mp") else{return false};inflight.insert("mp");busy=true;defer{inflight.remove("mp");busy = !inflight.isEmpty};let g=generation
        invalidateMPArtwork()
        do {
            let c=try client(.moviepilot), subs=try await c.subscriptions()
            guard g == generation && !locked else{return false}
            subscriptions=subs
            // Cached site statistics are ancillary; a failed site scrape must not hide subscriptions.
            if let accounts=try? await c.sites(), g == generation && !locked {sites=accounts}
            return g == generation && !locked
        }
        catch {if g == generation{clients[.moviepilot]=nil;message=Self.safeError(error)};return false}
    }
    func searchMoviePilot(_ query:String) async {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines);guard !q.isEmpty && !locked && !inflight.contains("search") else{return}
        inflight.insert("search");busy=true;defer{inflight.remove("search");busy=false}
        let g=generation
        do { let rows=try await client(.moviepilot).search(q);guard g == generation && !locked else{return};searchResults=rows }
        catch {if g == generation{clients[.moviepilot]=nil;message=Self.safeError(error)}}
    }
    func loadDiscovery() async {
        guard !locked && !Task.isCancelled else{return}
        if let job=discoveryJob { await job.value;return }
        invalidateMPArtwork()
        let cycle=UUID(),g=generation
        discoveryCycle=cycle;discoveryLoading=true
        let job=Task { @MainActor [weak self] in
            guard let self else{return}
            defer { if self.discoveryCycle == cycle { self.discoveryLoading=false;self.discoveryJob=nil;self.discoveryCycle=nil } }
            #if DEBUG
            if self.uiFixtureMode { self.discoverySections=UITestFixtures.sections();self.discoveryError=nil;self.discoveryUpdatedAt=Date();return }
            #endif
            do {
                let api=try self.client(.moviepilot)
                let rows=try await ReadBudget.run(seconds:self.readBudgetSeconds) { try await api.discoverySections() }
                guard g == self.generation && !self.locked && !Task.isCancelled else{return}
                self.discoverySections=rows;self.discoveryError=nil;self.discoveryUpdatedAt=Date()
            } catch {
                guard g == self.generation && !self.locked && !Task.isCancelled && !(error is CancellationError) else{return}
                self.discoveryError=Self.safeError(error)
            }
        }
        discoveryJob=job
        await withTaskCancellationHandler(operation:{ await job.value },onCancel:{ job.cancel() })
    }
    func searchDiscovery(_ query:String) async {
        discoverySearchGeneration &+= 1
        let epoch=discoverySearchGeneration, g=generation
        discoveryQuery=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !discoveryQuery.isEmpty && !locked else { discoveryResults=[];discoverySearchLoading=false;return }
        discoverySearchLoading=true;defer{if epoch == discoverySearchGeneration {discoverySearchLoading=false}}
        #if DEBUG
        if uiFixtureMode {discoveryResults=UITestFixtures.search(discoveryQuery);discoveryError=nil;return}
        #endif
        do {
            let api=try client(.moviepilot),query=discoveryQuery
            let rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.searchDiscovery(query) }
            guard epoch == discoverySearchGeneration && g == generation && !locked else{return}
            discoveryResults=rows;discoveryError=nil
        } catch { if epoch == discoverySearchGeneration && g == generation {discoveryError=Self.safeError(error)} }
    }
    func loadMediaDetail(_ item:MPDiscoveryItem) async throws -> MPDiscoveryDetail {
        #if DEBUG
        if uiFixtureMode {return UITestFixtures.detail(item)}
        #endif
        let g=generation, value=try await client(.moviepilot).mediaDetail(item)
        guard g == generation && !locked else {throw AppError.message("连接或锁定状态已变化，请重新读取详情。")}
        return value
    }
    func hasSubscription(_ item:MPDiscoveryItem,season:Int?) -> Bool {
        let source=item.mediaSource == "tmdb" ? "themoviedb":item.mediaSource
        return subscriptions.contains{$0.mediaSource == source && $0.mediaID == item.mediaID && $0.mediaType == item.canonicalType && (item.isMovie || $0.season == season)}
    }
    func resourceSites() async throws -> [MPResourceSite] {
        #if DEBUG
        if uiFixtureMode { return UITestFixtures.resourceSites() }
        #endif
        let g=generation,api=try client(.moviepilot)
        let rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.resourceSites() }
        try validateReadGeneration(g)
        return rows
    }
    func resourceDownloaders() async throws -> [MPResourceDownloader] {
        #if DEBUG
        if uiFixtureMode { return UITestFixtures.resourceDownloaders() }
        #endif
        let g=generation,api=try client(.moviepilot)
        let rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.resourceDownloaders() }
        try validateReadGeneration(g)
        return rows
    }
    func resourceDirectories() async throws -> [MPResourceDirectory] {
        let rows:[MPResourceDirectory]
        #if DEBUG
        if uiFixtureMode { rows=UITestFixtures.resourceDirectories() }
        else {
            let g=generation,api=try client(.moviepilot)
            rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.resourceDirectories() }
            try validateReadGeneration(g)
        }
        #else
        let g=generation,api=try client(.moviepilot)
        rows=try await ReadBudget.run(seconds:readBudgetSeconds) { try await api.resourceDirectories() }
        try validateReadGeneration(g)
        #endif
        resourceDirectoryOptions=rows
        preferences.validatePreferredDownloadDirectory(validIDs:Set(rows.map(\.id)),for:profile(.moviepilot).baseURL)
        return rows
    }
    func loadResourceDirectories() async {
        guard !resourceDirectoriesLoading && !locked else{return}
        resourceDirectoriesLoading=true;defer{resourceDirectoriesLoading=false}
        do { _=try await resourceDirectories();resourceDirectoriesError=nil }
        catch { if !(error is CancellationError) { resourceDirectoriesError=Self.safeError(error) } }
    }
    func searchResources(query:String,sites:[String],media:MPDiscoveryItem? = nil,season:Int? = nil) async throws -> [MPResourceItem] {
        #if DEBUG
        if uiFixtureMode { return stampResources(UITestFixtures.resourceSearch(query,sites:sites)) }
        #endif
        let g=generation,api=try client(.moviepilot)
        let rows=try await ReadBudget.run(seconds:150) { try await api.searchResources(query:query,sites:sites,media:media,season:season) }
        try validateReadGeneration(g)
        return stampResources(rows)
    }
    private func stampResources(_ rows:[MPResourceItem])->[MPResourceItem] {
        rows.map { var row=$0;row.connectionToken=resourceConnectionEpoch;return row }
    }
    func isCurrentResource(_ item:MPResourceItem)->Bool { item.connectionToken == resourceConnectionEpoch }
    private func validateReadGeneration(_ g:Int) throws {
        try Task.checkCancellation()
        guard g == generation && !locked else{throw AppError.message("连接或锁定状态已变化，请重新读取。")}
    }
    func canDownloadResource(_ downloader:MPResourceDownloader)->Bool {
        guard canManage(.moviepilot),downloader.targetBaseURL != nil,
              let kind=preferences.boundDownloaderKind(for:downloader.bindingID,baseURL:profile(.moviepilot).baseURL),
              downloader.compatibleKinds.contains(kind),canManage(kind) else{return false}
        return true
    }
    @discardableResult func downloadResource(_ request:MPResourceDownloadRequest) async -> Bool {
        do {
            try guardAction(.moviepilot)
            guard request.isValid,isCurrentResource(request.item),canDownloadResource(request.downloader),
                  let kind=preferences.boundDownloaderKind(for:request.downloader.bindingID,baseURL:profile(.moviepilot).baseURL) else {
                throw AppError.message("请先在设置中确认下载器对应关系并授权；只读锁和迁移保护仍然生效。")
            }
            actionInFlight=true;defer{actionInFlight=false}
            let g=generation,target=profile(kind),api=try client(.moviepilot)
            let ledger=ResourceDownloadLedger(defaults:defaults),key=ledger.key(profile:profile(.moviepilot),request:request,target:target)
            if let previous=try ledger.record(key) {
                throw AppError.message(previous.confirmedDownloadID == nil ? "该资源已有待核对的下载提交，请到原管理页核对，不会重复提交。" : "该资源已有下载提交记录，请在下载器中查看，不会重复添加。")
            }
            let id=try await api.downloadResource(request,authorize:{await self.resourceDownloadAllowed(request,generation:g,kind:kind,target:target)},beforeSend:{try await self.prepareResourceIntent(request,generation:g,kind:kind,target:target,key:key)})
            guard resourceDownloadAllowed(request,generation:g,kind:kind,target:target) else {
                throw AppError.message("下载可能已提交，连接或权限已变化。请只读核对原页面，勿重复提交。")
            }
            try ledger.confirm(key,id:id)
            message="MoviePilot 已接受下载任务。请到下载器查看进度；这不表示文件已经下载完成。"
            return true
        } catch {message=Self.safeError(error);return false}
    }
    private func resourceDownloadAllowed(_ request:MPResourceDownloadRequest,generation:Int,kind:ServiceKind,target:ServiceProfile)->Bool {
        self.generation == generation && !Task.isCancelled && canDownloadResource(request.downloader) &&
        isCurrentResource(request.item) &&
        preferences.boundDownloaderKind(for:request.downloader.bindingID,baseURL:profile(.moviepilot).baseURL) == kind &&
        profile(kind).baseURL == target.baseURL && profile(kind).username == target.username
    }
    private func prepareResourceIntent(_ request:MPResourceDownloadRequest,generation:Int,kind:ServiceKind,target:ServiceProfile,key:String) throws {
        guard resourceDownloadAllowed(request,generation:generation,kind:kind,target:target) else{throw AppError.message("权限或目标已变化，下载未提交。")}
        try ResourceDownloadLedger(defaults:defaults).prepare(key)
    }
    @discardableResult func createSubscription(_ request:MPSubscriptionRequest) async -> Bool {
        do {
            try guardAction(.moviepilot)
            guard request.isValid else{throw AppError.message("请选择有效作品和剧集季号。")}
            actionInFlight=true;defer{actionInFlight=false}
            let g=generation, c=try client(.moviepilot)
            let ledger=SubscriptionWriteLedger(defaults:defaults), key=ledger.key(profile:profile(.moviepilot),request:request)
            // Fresh reads may resolve old intents; an absent result never authorizes a retry.
            if let existing=try await c.existingSubscription(request) {
                guard g == generation && !locked else{throw AppError.message("连接或锁定状态已变化，请重新读取订阅。")}
                try ledger.confirm(key,id:existing.id);_ = await loadMoviePilot()
                message="MoviePilot 中已经有这项订阅，没有重复提交。";return true
            }
            guard try ledger.record(key) == nil else {throw AppError.message("这项作品已有提交记录，目前未查到明确结果。请到原 MoviePilot 只读核对，本应用不会重复提交。")}
            let id=try await c.createSubscription(request,authorize:{await self.actionAllowed(.moviepilot,generation:g)},beforeSend:{try await self.prepareSubscriptionIntent(request,generation:g)})
            guard g == generation && !locked else{throw AppError.message("订阅请求可能已提交，锁定或连接状态已变化，请到原页面核对，勿重复提交。")}
            guard let confirmed=try await c.existingSubscription(request), confirmed.id == id else {throw AppError.message("订阅已发送一次，回读尚未确认，请到原 MoviePilot 核对，勿重复提交。")}
            guard g == generation && !locked else{throw AppError.message("订阅请求已发送，连接或锁定状态已变化，请在原页面核对结果。")}
            try ledger.confirm(key,id:id);_ = await loadMoviePilot()
            message="已回读确认订阅。后续自动搜索和下载由 MoviePilot 现有规则执行。";return true
        } catch {message=Self.safeError(error);return false}
    }
    private func prepareSubscriptionIntent(_ request:MPSubscriptionRequest,generation:Int) throws {
        guard actionAllowed(.moviepilot,generation:generation) else{throw AppError.message("权限已变化，订阅未提交。")}
        let ledger=SubscriptionWriteLedger(defaults:defaults)
        try ledger.prepare(ledger.key(profile:profile(.moviepilot),request:request))
    }
    @discardableResult func loadEmby(_ query:String="") async -> Bool {
        guard !locked && !inflight.contains("emby") else{return false};inflight.insert("emby");busy=true;defer{inflight.remove("emby");busy=false};let g=generation
        do {let c=try client(.emby);let rows=try await c.embyLibrary(query),playing=try await c.embySessions();guard g == generation && !locked else{return false};library=rows;sessions=playing;return true}
        catch {if g == generation{clients[.emby]=nil;message=Self.safeError(error)};return false}
    }
    private func guardAction(_ kind:ServiceKind) throws {
        guard canManage(kind) else { throw AppError.message("此服务当前为只读。qB1/TR 迁移保护需要在迁移结束后解除。") }
        guard !actionInFlight else { throw AppError.message("上一项操作尚未完成。请等待并核对结果。") }
    }
    func performTask(_ task:TorrentTask,start:Bool) async {
        do {
            try guardAction(task.kind);actionInFlight=true;defer{actionInFlight=false}
            let g=generation;let c=try client(task.kind);let fresh=try await c.tasks()
            guard let current=fresh.first(where:{$0.id == task.id}) else { throw AppError.message("任务已变化或已迁移，请刷新后核对。") }
            guard current.verification == nil else { throw AppError.message("正在校验或等待校验的任务禁止在此操作。") }
            guard !current.tags.contains("本人发布") else { throw AppError.message("本人发布任务受保护，请使用原 qB 页面操作。") }
            guard (start ? current.isStopped:!current.isStopped) else { throw AppError.message("任务已处于目标状态，无需重复操作。") }
            try await c.taskAction(id:current.id,start:start,authorize:{await self.actionAllowed(task.kind,generation:g)})
            let verified=await loadTasks(task.kind);message=verified ? "请求已提交一次，请核对刷新后的任务状态。":"请求已提交一次，但列表回读未完成。请到原页面核对，勿重复点击。"
        } catch { message=Self.safeError(error) }
    }
    func setUploadLimit(_ kind:ServiceKind,mbps:Double) async {
        do { try guardAction(kind);guard kind.isDownloader else{throw AppError.message("服务类型不符。")};actionInFlight=true;defer{actionInFlight=false};let g=generation;try await client(kind).uploadLimit(mbps:mbps,authorize:{await self.actionAllowed(kind,generation:g)});await refresh(kind);message="上传限速请求已提交一次并回读确认。多个客户端下载器的限速不会自动合并。" }
        catch{message=Self.safeError(error)}
    }
    func setSubscriptionState(_ sub:Subscription,paused:Bool) async {
        do {try guardAction(.moviepilot);actionInFlight=true;defer{actionInFlight=false};let g=generation;try await client(.moviepilot).subscriptionState(id:sub.id,paused:paused,authorize:{await self.actionAllowed(.moviepilot,generation:g)});let verified=await loadMoviePilot();message=verified ? "订阅状态请求已提交。暂停不取消已经开始的搜索。":"订阅请求已提交，但回读未完成，请到原页面核对，勿重复点击。"}
        catch{message=Self.safeError(error)}
    }
    func setFavorite(_ item:MediaItem,value:Bool) async { await embyFlag(item,favorite:value,played:nil) }
    func setPlayed(_ item:MediaItem,value:Bool) async { await embyFlag(item,favorite:nil,played:value) }
    private func embyFlag(_ item:MediaItem,favorite:Bool?,played:Bool?) async {
        do {try guardAction(.emby);actionInFlight=true;defer{actionInFlight=false};let g=generation;try await client(.emby).embyFlag(id:item.id,favorite:favorite,played:played,authorize:{await self.actionAllowed(.emby,generation:g)});let verified=await loadEmby();message=verified ? "标记请求已接受，请核对列表。":"标记请求已接受，但回读未完成，请到 Emby 核对，勿重复点击。"}
        catch{message=Self.safeError(error)}
    }
    func webURL(_ kind:ServiceKind)->URL? {
        guard let base=try? EndpointPolicy.validate(profile(kind).baseURL) else{return nil}
        if kind == .tr { return URL(string:base.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/transmission/web/") }
        return base
    }
    private struct ImportFile:Decodable { var version:Int;var services:[ImportedService] }
    private struct ImportedService:Decodable { var kind:ServiceKind;var baseURL:String;var username:String;var password:String?;var apiKey:String? }
    func importProfile(_ url:URL) throws {
        let size=(try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        guard size > 0 && size <= 65536 else{throw AppError.message("连接文件为空或超过 64KB。")}
        let input=try JSONDecoder().decode(ImportFile.self,from:Data(contentsOf:url))
        guard input.version == 1 && !input.services.isEmpty && input.services.count <= 5 && Set(input.services.map{$0.kind}).count == input.services.count else{throw AppError.message("连接文件版本或服务清单无效。")}
        for s in input.services { _=try EndpointPolicy.validate(s.baseURL);guard !(s.password ?? "").isEmpty || !(s.apiKey ?? "").isEmpty else{throw AppError.message("连接文件缺少登录资料。")};if (s.apiKey ?? "").isEmpty && s.username.isEmpty{throw AppError.message("连接文件缺少用户名。")}}
        let oldProfiles=profiles;let old=Dictionary(uniqueKeysWithValues:input.services.map{($0.kind,credential($0.kind))})
        do { for s in input.services { try saveConnection(s.kind,baseURL:s.baseURL,username:s.username,password:s.password ?? "",apiKey:s.apiKey ?? "",allowActions:false) } }
        catch { profiles=oldProfiles;persist();for(k,v) in old { if v.isEmpty{KeychainStore.delete(k)}else{try? KeychainStore.write(v,kind:k)} };clients=[:];throw error }
        migrationProtection=true;readOnlyMode=true;message="已导入 \(input.services.count) 个连接，全局只读锁已开启，管理开关保持关闭。请删除“文件”中含密码的导入文件。"
    }
    func unlock() async {
        guard biometricEnabled else{locked=false;return}
        let context=LAContext();context.localizedCancelTitle="取消"
        do { if try await context.evaluatePolicy(.deviceOwnerAuthentication,localizedReason:"解锁家庭媒体管理与登录资料") { locked=false;await refreshAll() } }
        catch { message="未解锁。可使用系统允许的生物识别或设备密码重试。" }
    }
    private func actionAllowed(_ kind:ServiceKind,generation:Int)->Bool {self.generation == generation && canManage(kind)}
    func loadPoster(_ id:String) async -> Data? {
        guard !locked && isConfigured(.emby) else{return nil}
        if let d=posterCache.object(forKey:id as NSString){return d as Data}
        let g=generation
        do{let data=try await client(.emby).embyImage(id);guard generation == g && !locked else{return nil};posterCache.setObject(data as NSData,forKey:id as NSString,cost:data.count);return data}catch{return nil}
    }
    func loadMPArtwork(_ reference:String,forceReload:Bool=false) async -> Data? {
        guard !reference.isEmpty && !locked && !Task.isCancelled && isConfigured(.moviepilot) else{return nil}
        #if DEBUG
        if uiFixtureMode { return UITestFixtures.artwork(reference) }
        #endif
        let epoch=resourceConnectionEpoch,refresh=mpArtworkRefreshToken
        let key=epoch.uuidString+"|"+reference
        if forceReload {
            mpArtworkCache.removeObject(forKey:key as NSString)
            mpArtworkJobs.removeValue(forKey:key)?.1.cancel()
        }
        if let cached=mpArtworkCache.object(forKey:key as NSString) {return cached as Data}
        if let job=mpArtworkJobs[key] {
            let data=await job.1.value
            return !Task.isCancelled && !locked && epoch == resourceConnectionEpoch && refresh == mpArtworkRefreshToken ? data:nil
        }
        guard let api=try? client(.moviepilot) else{return nil}
        let id=UUID(),gate=mpArtworkGate,budget=min(18,readBudgetSeconds)
        let job=Task { @MainActor [weak self] () -> Data? in
            guard let self else{return nil}
            do {
                let data=try await ReadBudget.run(seconds:budget) {
                    try await gate.read { try await api.moviePilotArtwork(reference) }
                }
                guard !Task.isCancelled && !self.locked && epoch == self.resourceConnectionEpoch && refresh == self.mpArtworkRefreshToken else{return nil}
                self.mpArtworkCache.setObject(data as NSData,forKey:key as NSString,cost:data.count)
                return data
            } catch { return nil }
        }
        mpArtworkJobs[key]=(id,job)
        let data=await job.value
        if mpArtworkJobs[key]?.0 == id {mpArtworkJobs[key]=nil}
        return !Task.isCancelled && !locked && epoch == resourceConnectionEpoch && refresh == mpArtworkRefreshToken ? data:nil
    }
    func invalidateMPArtwork() {
        for entry in mpArtworkJobs.values {entry.1.cancel()}
        mpArtworkJobs.removeAll();mpArtworkCache.removeAllObjects()
        mpArtworkRefreshToken=UUID()
    }
    func cancelDashboardRefresh() { dashboardJob?.cancel() }
    func cancelDiscoveryRefresh() { discoveryJob?.cancel() }
    private func resetReadJobs() {
        invalidateMPArtwork()
        dashboardJob?.cancel();discoveryJob?.cancel()
        dashboardJob=nil;dashboardCycle=nil;discoveryJob=nil;discoveryCycle=nil
        dashboardRefreshing=false;dashboardManualRefreshing=false;discoveryLoading=false
    }
    func protectOnBackground() {
        generation &+= 1;discoverySearchGeneration &+= 1
        interactionEpoch=UUID()
        invalidateMPArtwork()
        dashboardJob?.cancel();discoveryJob?.cancel()
        if biometricEnabled { locked=true };clients=[:]
    }
}
