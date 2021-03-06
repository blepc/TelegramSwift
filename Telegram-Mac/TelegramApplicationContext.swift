//
//  TelegramApplicationContext.swift
//  TelegramMac
//
//  Created by keepcoder on 28/11/2016.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import TGUIKit
import SwiftSignalKitMac
import TelegramCoreMac
import PostboxMac

struct TemporaryPasswordContainer {
    let date: TimeInterval
    let password: String
    
    var isActive: Bool {
        return date + 15 * 60 > Date().timeIntervalSince1970
    }
}

public var isDebug = false



class TelegramApplicationContext : NSObject {
    var layout:SplitViewState = .none
    let layoutHandler:ValuePromise<SplitViewState> = ValuePromise(ignoreRepeated:true)
    private(set) var mediaKeyTap:SPMediaKeyTap?
    let entertainment:EntertainmentViewController
    private var _recentlyPeerUsed:[PeerId] = []
    let cachedAdminIds: CachedAdminIds = CachedAdminIds()
    let mainViewController: MainViewController
    let cancelGlobalSearch:ValuePromise<Bool> = ValuePromise(ignoreRepeated: false)
    let archiver: ArchiverContext = ArchiverContext()
    let chatUndoManager = ChatUndoManager()
    let peerChannelMemberCategoriesContextsManager = PeerChannelMemberCategoriesContextsManager()
    
    private(set) var timeDifference:TimeInterval  = 0
    private(set) var recentlyPeerUsed:[PeerId] {
        set {
            _recentlyPeerUsed = newValue
        }
        get {
            if _recentlyPeerUsed.count > 2 {
                return Array(_recentlyPeerUsed.prefix(through: 2))
            } else {
                return _recentlyPeerUsed
            }
        }
    }
    
    var globalSearch:((String)->Void)?
    
    private let logoutDisposable = MetaDisposable()
    
    var switchSplitLayout:((SplitViewState)->Void)?
    
    weak var mainNavigation:NavigationViewController?
    private let updateDifferenceDisposable = MetaDisposable()
    private let temporaryPwdDisposable = MetaDisposable()
    private let createSecretChatDisposable = MetaDisposable()
    let fetchManager: FetchManager
    
    init(_ mainNavigation:NavigationViewController?, _ entertainment:EntertainmentViewController, _ mainViewController: MainViewController, network: Network, postbox: Postbox) {
        self.mainNavigation = mainNavigation
        self.entertainment = entertainment
        self.fetchManager = FetchManager(postbox: postbox)
        self.mainViewController = mainViewController
        
        globalPeerHandler.set(.single(nil))
        
        if network.globalTime > 0 {
            timeDifference = network.globalTime - Date().timeIntervalSince1970
        }
        super.init()
        
        
        _ = layoutHandler.get().start(next: { [weak self] (state) in
            self?.layout = state
        })
        
        updateDifferenceDisposable.set((Signal<Void, NoError>.single(Void())
            |> delay(5 * 60, queue: Queue.mainQueue()) |> restart).start(next: { [weak self, weak network] in
                if let network = network, network.globalTime > 0 {
                    self?.timeDifference = network.globalTime - Date().timeIntervalSince1970
                }
            }))
        
    }
    
    func showCallHeader(with session:PCallSession) {
        mainNavigation?.callHeader?.show(true)
        if let view = mainNavigation?.callHeader?.view as? CallNavigationHeaderView {
            view.update(with: session)
        }
    }
    
    func checkFirstRecentlyForDuplicate(peerId:PeerId) {
        if let index = recentlyPeerUsed.index(of: peerId), index == 0 {
            recentlyPeerUsed.remove(at: index)
        }
    }
    
    func addRecentlyUsedPeer(peerId:PeerId) {
        if let index = recentlyPeerUsed.index(of: peerId) {
            recentlyPeerUsed.remove(at: index)
        }
        recentlyPeerUsed.insert(peerId, at: 0)
        if recentlyPeerUsed.count > 4 {
            recentlyPeerUsed = Array(recentlyPeerUsed.prefix(through: 4))
        }
    }
    
    deinit {
        updateDifferenceDisposable.dispose()
        temporaryPwdDisposable.dispose()
        createSecretChatDisposable.dispose()
    }
    
    
    func deinitMediaKeyTap() {
        mediaKeyTap?.stopWatchingMediaKeys()
        mediaKeyTap = nil
    }
    
    func initMediaKeyTap() {
        mediaKeyTap = SPMediaKeyTap(delegate: self)
    }

    override func mediaKeyTap(_ keyTap: SPMediaKeyTap, receivedMediaKeyEvent event: NSEvent) {
        let keyCode: Int32 = (Int32((event.data1 & 0xffff0000) >> 16))
        let keyFlags: Int = (event.data1 & 0x0000ffff)
        let keyIsPressed: Bool = ((keyFlags & 0xff00) >> 8) == 0xa
        if keyIsPressed {
            switch keyCode {
            case NX_KEYTYPE_PLAY:
                globalAudio?.playOrPause()
            case NX_KEYTYPE_FAST:
                globalAudio?.next()
            case NX_KEYTYPE_REWIND:
                globalAudio?.prev()
            default:
                break
            }
        }
    }
    
    private var _temporartPassword: String?
    var temporaryPassword: String? {
        return _temporartPassword
    }
    
    func resetTemporaryPwd() {
        _temporartPassword = nil
        temporaryPwdDisposable.set(nil)
    }
    
    func setTemporaryPwd(_ password: String) -> Void {
        _temporartPassword = password
        let signal = Signal<Void, NoError>.single(Void()) |> delay(30 * 60, queue: Queue.mainQueue())
        temporaryPwdDisposable.set(signal.start(next: { [weak self] in
            self?._temporartPassword = nil
        }))
    }
    
    func composeCreateGroup(_ account: Account) {
        guard let navigation = mainNavigation else {return}
        createGroup(with: account, for: navigation)
    }
    func composeCreateChannel(_ account: Account) {
        guard let navigation = mainNavigation else {return}
        createChannel(with: account, for: navigation)
    }
    func composeCreateSecretChat(_ account: Account) {
        let confirmationImpl:([PeerId])->Signal<Bool, NoError> = { peerIds in
            if let first = peerIds.first, peerIds.count == 1 {
                return account.postbox.loadedPeerWithId(first) |> deliverOnMainQueue |> mapToSignal { peer in
                    return confirmSignal(for: mainWindow, information: tr(L10n.composeConfirmStartSecretChat(peer.displayTitle)))
                }
            }
            return confirmSignal(for: mainWindow, information: tr(L10n.peerInfoConfirmAddMembers1Countable(peerIds.count)))
        }
        let select = selectModalPeers(account: account, title: tr(L10n.composeSelectSecretChat), limit: 1, confirmation: confirmationImpl)
        
        let create = select |> map { $0.first! } |> mapToSignal { peerId in
            return createSecretChat(account: account, peerId: peerId) |> `catch` {_ in .complete()}
            } |> deliverOnMainQueue |> mapToSignal{ peerId -> Signal<PeerId, NoError> in
                return showModalProgress(signal: .single(peerId), for: mainWindow)
        }
        
        createSecretChatDisposable.set(create.start(next: { [weak self] peerId in
            self?.mainNavigation?.push(ChatController(account: account, chatLocation: .peer(peerId)))
        }))
    }
    
}
