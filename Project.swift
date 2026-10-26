import Foundation
import ProjectDescription

let projectMarketingVersion: SettingValue = "0.0.0"
let projectBuildVersion: SettingValue = "0.0.0"
let shouldBundleLocalConfig = ProcessInfo.processInfo.environment["TUIST_REMOTE_CODER_BUNDLE_LOCAL_CONFIG"] == "1"
let isDevelopmentPerfBuild = ProcessInfo.processInfo.environment["TUIST_REMOTE_CODER_PERF_SIGNING"] == "development"
let performanceHarnessInfo: [String: Plist.Value] = ProcessInfo.processInfo.environment["TUIST_REMOTE_CODER_PERF_HARNESS_SHA256"]
    .map { ["RemoteCoderPerfHarnessSHA256": .string($0)] } ?? [:]
let remoteCoderResources: ResourceFileElements = shouldBundleLocalConfig
    ? [
        "RemoteCoder/Assets.xcassets",
        "THIRD_PARTY_NOTICES.md",
        .folderReference(path: "LICENSES"),
        "RemoteCoder/Resources/**",
    ]
    : [
        "RemoteCoder/Assets.xcassets",
        "THIRD_PARTY_NOTICES.md",
        .folderReference(path: "LICENSES"),
        .glob(
            pattern: "RemoteCoder/Resources/**",
            excluding: [
                "RemoteCoder/Resources/RemoteCoderLocalConfig.json",
            ]
        ),
    ]

let commonSwiftSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_WARN_CONCURRENCY": "YES",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "CODE_SIGN_STYLE": "Automatic",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "MARKETING_VERSION": projectMarketingVersion,
    "CURRENT_PROJECT_VERSION": projectBuildVersion,
    "RC_BUILD_ID": "unrecorded",
    "RC_SOURCE_COMMIT": "unrecorded",
    "RC_SOURCE_MODIFIED": "unrecorded",
    "RC_SOURCE_FINGERPRINT": "unrecorded",
    "INFOPLIST_KEY_CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "INFOPLIST_KEY_CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
]

let releaseSigningSettings: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Manual",
    "CODE_SIGN_IDENTITY": isDevelopmentPerfBuild ? "Apple Development" : "Apple Distribution",
]

func remoteCoderTargetSettings(
    _ base: SettingsDictionary,
    releaseSettings: SettingsDictionary = [:]
) -> Settings {
    let mergedReleaseSettings = releaseSigningSettings.merging(releaseSettings) { _, new in new }

    return .settings(
        base: base,
        configurations: [
            .debug(name: .debug, xcconfig: "Config/RemoteCoder.xcconfig"),
            .release(name: .release, settings: mergedReleaseSettings, xcconfig: "Config/RemoteCoder.xcconfig"),
        ]
    )
}

let macAppSourceFolders = [
    "App", "Chat", "Platform/macOS", "Platform/Shared", "Services", "UI", "Workspace",
]
let macUnsupportedSources: [Path] = [
    "RemoteCoder/App/App.swift",
    "RemoteCoder/App/CodexIntentOptions.swift",
    "RemoteCoder/App/RemoteCoderAppShortcuts.swift",
    "RemoteCoder/App/RemoteCoderQuickActions.swift",
    "RemoteCoder/App/VoiceModeIntentOptions.swift",
    "RemoteCoder/Services/RealtimeVoice/RealtimeWebRTCSession.swift",
    "RemoteCoder/Services/RealtimeVoice/VoiceCall.swift",
    "RemoteCoder/UI/Chat/VoiceMode/**",
    "RemoteCoder/UI/Conversations/ConversationDrawer.swift",
    "RemoteCoder/UI/Settings/LocationSettingsSection.swift",
    "RemoteCoder/UI/Settings/RealtimeVoiceSettingsSection.swift",
]
let macAppSourceGlobs: [SourceFileGlob] = [
    .glob("Core/Sources/RemoteCoderCore/**/*.swift"),
    .glob(
        "Shared/**/*.swift",
        excluding: [
            "Shared/AppExtensionContract/RemoteCoderActiveTasksAttributes.swift",
            "Shared/AppExtensionContract/RemoteCoderCameraCaptureIntent.swift",
            "Shared/AppExtensionContract/RemoteCoderVoiceCallAttributes.swift",
            "Shared/CameraCapture/**",
            "Shared/LiveNavigationContract/**",
        ]
    ),
] + macAppSourceFolders.map { folder in
    SourceFileGlob.glob(Path("RemoteCoder/\(folder)/**/*.swift"), excluding: macUnsupportedSources)
}

let project = Project(
    name: "RemoteCoder",
    options: .options(disableBundleAccessors: true, disableSynthesizedResourceAccessors: true),
    packages: [
        .package(
            url: "https://github.com/emileberhard/SpeechKit.git",
            .exact("0.1.0")
        ),
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            .exact("152.0.0")
        ),
        .package(
            url: "https://github.com/googlemaps/ios-navigation-sdk",
            .exact("11.1.0")
        ),
    ],
    targets: [
        .target(
            name: "RemoteCoder",
            destinations: .iOS,
            product: .app,
            bundleId: "$(RC_BUNDLE_ID)",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CADisableMinimumFrameDurationOnPhone": true,
                "CFBundleDisplayName": "RemoteCoder",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleURLTypes": .array([
                    .dictionary([
                        "CFBundleURLName": .string("remotecoder"),
                        "CFBundleURLSchemes": .array([.string("remotecoder")]),
                    ]),
                ]),
                "ITSAppUsesNonExemptEncryption": false,
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsArbitraryLoads": true,
                ]),
                "NSCameraUsageDescription": "Take photos you attach to messages or ask your coding agent to capture.",
                "NSPhotoLibraryAddUsageDescription": "Save photos you take with RemoteCoder to your camera roll.",
                "NSLocalNetworkUsageDescription": "RemoteCoder connects directly to your gateway when both are on the same network.",
                "NSLocationAlwaysAndWhenInUseUsageDescription": "RemoteCoder shares your live location with your own agents while a navigation or tour-companion session is active.",
                "NSLocationTemporaryUsageDescriptionDictionary": .dictionary([
                    "LiveNavigation": .string("Precise location lets your agent anticipate turns and describe nearby places while you move."),
                ]),
                "NSLocationWhenInUseUsageDescription": "RemoteCoder uses your location for agent-guided navigation and live tour commentary.",
                "NSMicrophoneUsageDescription": "RemoteCoder uses the microphone for realtime voice conversations and message dictation.",
                "NSMotionUsageDescription": "RemoteCoder uses motion data to improve navigation altitude and route accuracy.",
                "NSSupportsLiveActivities": true,
                "RemoteCoderDictationContainer": "$(RC_ICLOUD_CONTAINER)",
                "RemoteCoderAPNSEnvironment": "$(RC_APNS_ENVIRONMENT)",
                "RemoteCoderBuildID": "$(RC_BUILD_ID)",
                "RemoteCoderSourceCommit": "$(RC_SOURCE_COMMIT)",
                "RemoteCoderSourceModified": "$(RC_SOURCE_MODIFIED)",
                "RemoteCoderSourceFingerprint": "$(RC_SOURCE_FINGERPRINT)",
                "RemoteCoderBuildOptimization": "$(SWIFT_OPTIMIZATION_LEVEL)",
                "UIApplicationSceneManifest": [
                    "UIApplicationSupportsMultipleScenes": false,
                    "UISceneConfigurations": [:],
                ],
                "UIApplicationSupportsIndirectInputEvents": true,
                "BGTaskSchedulerPermittedIdentifiers": ["$(RC_BUNDLE_ID).upload.*"],
                "UIBackgroundModes": ["audio", "location", "voip"],
                "UILaunchScreen": [:],
                "UISupportedInterfaceOrientations": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
                "UISupportedInterfaceOrientations~ipad": [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ],
            ].merging(performanceHarnessInfo) { _, value in value }),
            sources: ["Shared/**/*.swift"],
            resources: remoteCoderResources,
            buildableFolders: [
                "RemoteCoder/App",
                "RemoteCoder/Chat",
                "RemoteCoder/Platform/iOS",
                "RemoteCoder/Platform/Shared",
                "RemoteCoder/Services",
                "RemoteCoder/UI",
                "RemoteCoder/Workspace",
                "Core/Sources/RemoteCoderCore",
            ],
            dependencies: [
                .sdk(name: "AppIntents", type: .framework),
                .package(product: "SpeechKit"),
                .package(product: "DictationLibrary"),
                .package(product: "WebRTC"),
                .package(product: "GoogleNavigation"),
                .target(name: "RemoteCoderNotificationService"),
                .target(name: "RemoteCoderLocationPushService"),
                .target(name: "RemoteCoderLiveActivities"),
                .target(name: "RemoteCoderShareExtension"),
                .target(name: "RemoteCoderCaptureExtension"),
            ],
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "CODE_SIGN_ENTITLEMENTS": isDevelopmentPerfBuild
                        ? "RemoteCoder/Entitlements/RemoteCoder.Debug.entitlements"
                        : "RemoteCoder/Entitlements/RemoteCoder.$(CONFIGURATION).entitlements",
                    "OTHER_LDFLAGS": "$(inherited) -Wl,-no_objc_class_refs_in_got",
                    "PRODUCT_NAME": "RemoteCoder",
                    "PROVISIONING_PROFILE_SPECIFIER": "",
                    "RC_APNS_ENVIRONMENT": "development",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) REMOTE_CODER_APP",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_REMOTECODER_APP)",
                    "RC_APNS_ENVIRONMENT": "production",
                ]
            )
        ),
        .target(
            name: "RemoteCoderMac",
            destinations: .macOS,
            product: .app,
            bundleId: "$(RC_BUNDLE_ID)",
            deploymentTargets: .macOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoder",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleURLTypes": .array([
                    .dictionary([
                        "CFBundleURLName": .string("remotecoder"),
                        "CFBundleURLSchemes": .array([.string("remotecoder")]),
                    ]),
                ]),
                "ITSAppUsesNonExemptEncryption": false,
                "LSApplicationCategoryType": "public.app-category.developer-tools",
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsArbitraryLoads": true,
                ]),
                "NSLocalNetworkUsageDescription": "RemoteCoder connects directly to your gateway when both are on the same network.",
                "NSMicrophoneUsageDescription": "RemoteCoder uses the microphone for message dictation.",
                "RemoteCoderDictationContainer": "$(RC_ICLOUD_CONTAINER)",
                "RemoteCoderAPNSEnvironment": "$(RC_APNS_ENVIRONMENT)",
                "RemoteCoderBuildID": "$(RC_BUILD_ID)",
                "RemoteCoderSourceCommit": "$(RC_SOURCE_COMMIT)",
                "RemoteCoderSourceModified": "$(RC_SOURCE_MODIFIED)",
                "RemoteCoderSourceFingerprint": "$(RC_SOURCE_FINGERPRINT)",
                "RemoteCoderBuildOptimization": "$(SWIFT_OPTIMIZATION_LEVEL)",
            ].merging(performanceHarnessInfo) { _, value in value }),
            sources: SourceFilesList(globs: macAppSourceGlobs),
            resources: remoteCoderResources,
            dependencies: [
                .package(product: "SpeechKit"),
                .package(product: "DictationLibrary"),
            ],
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.filter { $0.key != "TARGETED_DEVICE_FAMILY" }.merging([
                    "CODE_SIGN_ENTITLEMENTS": "RemoteCoder/Entitlements/RemoteCoderMac.$(CONFIGURATION).entitlements",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "PRODUCT_NAME": "RemoteCoder",
                    "PROVISIONING_PROFILE_SPECIFIER": "",
                    "RC_APNS_ENVIRONMENT": "development",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_REMOTECODER_MAC)",
                    "RC_APNS_ENVIRONMENT": "production",
                ]
            )
        ),
        .target(
            name: "RemoteCoderLocationPushService",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "$(RC_BUNDLE_ID).RemoteCoderLocationPushService",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoderLocationPushService",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsArbitraryLoads": true,
                ]),
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.location.push.service"),
                    "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).LocationPushService"),
                ]),
            ]),
            sources: [
                "RemoteCoderLocationPushService/**/*.swift",
                "Shared/LiveNavigationContract/**/*.swift",
                "Shared/AppExtensionContract/AppGroup.swift",
            ],
            entitlements: .file(path: "RemoteCoderLocationPushService/RemoteCoderLocationPushService.entitlements"),
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "APPLICATION_EXTENSION_API_ONLY": "YES",
                    "PRODUCT_NAME": "RemoteCoderLocationPushService",
                    "SKIP_INSTALL": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_LOCATION_PUSH_SERVICE)",
                ]
            )
        ),
        .target(
            name: "RemoteCoderNotificationService",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "$(RC_BUNDLE_ID).RemoteCoderNotificationService",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoderNotificationService",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "RemoteCoderNotificationSoundOrigins": "$(RC_NOTIFICATION_SOUND_ORIGINS)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.usernotifications.service"),
                    "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).NotificationService"),
                ]),
            ]),
            sources: [
                "RemoteCoderNotificationService/**/*.swift",
                "Core/Sources/RemoteCoderCore/Notifications/NotificationSoundPolicy.swift",
                "Shared/AppExtensionContract/AppGroup.swift",
                "Shared/AppExtensionContract/NotificationContract.swift",
            ],
            entitlements: .file(path: "RemoteCoderNotificationService/RemoteCoderNotificationService.entitlements"),
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "APPLICATION_EXTENSION_API_ONLY": "YES",
                    "PRODUCT_NAME": "RemoteCoderNotificationService",
                    "SKIP_INSTALL": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_NOTIFICATION_SERVICE)",
                ]
            )
        ),
        .target(
            name: "RemoteCoderLiveActivities",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "$(RC_BUNDLE_ID).RemoteCoderLiveActivities",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoderLiveActivities",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.widgetkit-extension"),
                ]),
            ]),
            sources: [
                "RemoteCoderLiveActivities/**/*.swift",
                "Shared/AppExtensionContract/**/*.swift",
                "Core/Sources/RemoteCoderCore/Turns/ActiveTasksLiveActivityContent.swift",
            ],
            resources: [
                "RemoteCoderLiveActivities/Assets.xcassets",
            ],
            entitlements: .file(path: "RemoteCoderLiveActivities/RemoteCoderLiveActivities.entitlements"),
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "APPLICATION_EXTENSION_API_ONLY": "YES",
                    "PRODUCT_NAME": "RemoteCoderLiveActivities",
                    "SKIP_INSTALL": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_LIVE_ACTIVITIES)",
                ]
            )
        ),
        .target(
            name: "RemoteCoderShareExtension",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "$(RC_BUNDLE_ID).RemoteCoderShareExtension",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoder",
                "RemoteCoderAppGroup": "$(RC_APP_GROUP)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSExtension": .dictionary([
                    "NSExtensionPointIdentifier": .string("com.apple.share-services"),
                    "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).ShareViewController"),
                    "NSExtensionAttributes": .dictionary([
                        "NSExtensionActivationRule": .string(
                            "SUBQUERY(extensionItems, $item, SUBQUERY($item.attachments, $attachment, "
                                + "ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO \"public.item\").@count > 0).@count > 0"
                        ),
                    ]),
                ]),
            ]),
            sources: [
                "RemoteCoderShareExtension/**/*.swift",
                "Core/Sources/RemoteCoderCore/Files/SharedItemsInbox.swift",
                "Shared/AppExtensionContract/AppGroup.swift",
                "Shared/AppExtensionContract/RemoteCoderDeepLinks.swift",
            ],
            entitlements: .file(path: "RemoteCoderShareExtension/RemoteCoderShareExtension.entitlements"),
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "APPLICATION_EXTENSION_API_ONLY": "YES",
                    "PRODUCT_NAME": "RemoteCoderShareExtension",
                    "SKIP_INSTALL": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_SHARE_EXTENSION)",
                ]
            )
        ),
        .target(
            name: "RemoteCoderCaptureExtension",
            destinations: .iOS,
            product: .extensionKitExtension,
            bundleId: "$(RC_BUNDLE_ID).RemoteCoderCaptureExtension",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "RemoteCoder Camera",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSCameraUsageDescription": "Take a photo to attach to a new RemoteCoder chat.",
                "NSPhotoLibraryAddUsageDescription": "Save photos you take with RemoteCoder to your camera roll.",
                "EXAppExtensionAttributes": .dictionary([
                    "EXExtensionPointIdentifier": .string("com.apple.securecapture"),
                ]),
            ]),
            sources: [
                "RemoteCoderCaptureExtension/**/*.swift",
                "Shared/CameraCapture/**/*.swift",
                "Shared/AppExtensionContract/RemoteCoderCameraCaptureIntent.swift",
                "Core/Sources/RemoteCoderCore/Files/CameraCaptureBatch.swift",
                "Core/Sources/RemoteCoderCore/Workspace/OwnedTasks.swift",
            ],
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "APPLICATION_EXTENSION_API_ONLY": "YES",
                    "PRODUCT_NAME": "RemoteCoderCaptureExtension",
                    "SKIP_INSTALL": "YES",
                    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
                ]) { _, new in new },
                releaseSettings: [
                    "PROVISIONING_PROFILE_SPECIFIER": "$(RC_PROFILE_CAPTURE_EXTENSION)",
                ]
            )
        ),
        .target(
            name: "RemoteCoderTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "$(RC_BUNDLE_ID)Tests",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .default,
            resources: ["protocol-fixtures/**/*.json", "RemoteCoderTests/Fixtures/*.pcm"],
            buildableFolders: ["RemoteCoderTests", "Core/Tests/RemoteCoderCoreTests/SharedSupport"],
            dependencies: [
                .target(name: "RemoteCoder"),
            ],
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "PRODUCT_NAME": "RemoteCoderTests",
                    "SKIP_INSTALL": "YES",
                ]) { _, new in new }
            )
        ),
        // Kept out of the `RemoteCoder` scheme on purpose: these drive the real
        // app and need a simulator with several gateways configured, which the
        // hermetic unit suite must not depend on.
        .target(
            name: "RemoteCoderUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "$(RC_BUNDLE_ID)UITests",
            deploymentTargets: .iOS("27.0"),
            infoPlist: .default,
            buildableFolders: ["RemoteCoderUITests"],
            dependencies: [
                .target(name: "RemoteCoder"),
            ],
            settings: remoteCoderTargetSettings(
                commonSwiftSettings.merging([
                    "PRODUCT_NAME": "RemoteCoderUITests",
                    "SKIP_INSTALL": "YES",
                ]) { _, new in new }
            )
        ),
    ],
    schemes: [
        .scheme(
            name: "RemoteCoder",
            shared: true,
            buildAction: .buildAction(targets: ["RemoteCoder"]),
            testAction: .targets(
                ["RemoteCoderTests"],
                arguments: .arguments(environmentVariables: [
                    "RUN_REMOTE_CODER_TRANSCRIPTION_INTEGRATION_TESTS": .environmentVariable(
                        value: Environment.rcLiveGateway.getString(default: "0"), isEnabled: true),
                ]),
                configuration: .debug,
                expandVariableFromTarget: "RemoteCoderTests",
                diagnosticsOptions: .options(mainThreadCheckerEnabled: false)
            ),
            runAction: .runAction(configuration: .debug, executable: "RemoteCoder"),
            archiveAction: .archiveAction(configuration: .release),
            profileAction: .profileAction(configuration: .release, executable: "RemoteCoder"),
            analyzeAction: .analyzeAction(configuration: .debug)
        ),
        .scheme(
            name: "RemoteCoderMac",
            shared: true,
            buildAction: .buildAction(targets: ["RemoteCoderMac"]),
            runAction: .runAction(configuration: .debug, executable: "RemoteCoderMac"),
            archiveAction: .archiveAction(configuration: .release),
            profileAction: .profileAction(configuration: .release, executable: "RemoteCoderMac"),
            analyzeAction: .analyzeAction(configuration: .debug)
        ),
        .scheme(
            name: "RemoteCoderUITests",
            shared: true,
            buildAction: .buildAction(targets: ["RemoteCoder", "RemoteCoderUITests"]),
            testAction: .targets(
                ["RemoteCoderUITests"],
                configuration: .debug,
                expandVariableFromTarget: "RemoteCoderUITests",
                diagnosticsOptions: .options(mainThreadCheckerEnabled: false)
            ),
            runAction: .runAction(configuration: .debug, executable: "RemoteCoder"),
            analyzeAction: .analyzeAction(configuration: .debug)
        ),
    ]
)
