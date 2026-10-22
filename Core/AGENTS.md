# Mac-native Swift logic

The repository root and [iOS area instructions](../RemoteCoder/AGENTS.md) apply.

`just core-test [filter]` runs this package on the configured build host without an iOS
simulator, app host, signing, or provider services. These production sources
are also compiled directly by the Tuist app target. There is one source owner;
never duplicate definitions or maintain a separate implementation for tests.
Keep iOS-only imports and view hosting outside this package. Mac-native tests
belong here, in the same domain folders as their sources; affected iOS
integration tests use the explicit simulator recipes and the root's selective
testing policy.

## Domain owners

Sources are grouped by domain under `Sources/RemoteCoderCore/`. Add a type to
the folder that owns its concept; [Glossary](../docs/glossary.md) names each
owner.

| Folder | Owns |
|---|---|
| `Wire/{AppServer,JSONRPC,Extensions}` | App-server v2 wire mirrors, envelopes and `ServerNotification` (decoded once), typed gateway extension params and results |
| `Storage`, `Hosts` | `HostStorage` and `StorageScope`; `HostStore`, credentials, `GatewayRoutes`, LAN endpoint, `LocalConfiguration`, `HostPreferences`, `HostDirectories` |
| `Gateway` | The connection actor, `GatewayEventPump`, `ReplayProgress`, `DispatchPolicy`, notification routing |
| `Conversations` | `ConversationAddress`, `ConversationSession`/`ConversationState`, projection, checkpoints, drafts, `TranscriptRecovery`, `ConversationWarmer`, `RecentConversationCache` |
| `Conversations/{History,Metadata,Activity,Agents,Sidebar}` | History window, cache and scheduler, conversation index and header store; metadata DTOs and store; busy reconciliation; agents model; sidebar projection, pin and attention stores, drawer placement |
| `Workspace` | `TargetLifecycle`, `TargetPresentation`, owned-task tracking |
| `Turns`, `Questions` | `TurnRegistry`, `ActiveJob`, `TurnDispatcher`, `TurnStops`; `QuestionReplica`, question flow and editor logic |
| `Accounts`, `Models`, `Usage` | Account models and names; `AgentProvider`, model and reasoning catalogs, `NewChatDefaults`, `ModelPickerPreferences`; usage rows |
| `Files`, `Directories`, `Images`, `Voice`, `Notifications` | Host file references, uploads and staging; `DirectoryTree`; image preparation; realtime wire, voice history and call values; completion payloads, routing and `DeviceRegistration` |
| `Feedback`, `Energy`, `Diagnostics`, `Concurrency` | The pure haptic event catalog; `AppEnergyPolicy`; `DiagnosticsOutbox` and performance records; `BoundedFanOut` |

A type that needs UIKit, SpeechKit, WebRTC or another platform framework stays
in the app. That includes the SpeechKit recording writer, the platform
`Pasteboard`, and the iOS bridges under `RemoteCoder/Platform/`.
