
import type { Thread } from "./Thread";
import type { ThreadObservationCheckpoint } from "./ThreadObservationCheckpoint";

export type ThreadSubscribeResponse = { "status": "notLoaded" } | { "status": "subscribed", subscriptionId: string, thread: Thread, checkpoint: ThreadObservationCheckpoint, };
