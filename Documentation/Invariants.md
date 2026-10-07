# Invariants

These are the rules later changes have to keep. Breaking one of them shows up as a stalled picture, a seek that plays the wrong minute, or a late callback painting the previous movie.

## Session generation

`PlayerSession` has one generation. `beginOpen`, `beginSeek`, and `close` cancel the previous token and add one to the generation. Every delayed block captured the generation it started with. `adopt` and `isCurrent` reject anything else. A result from movie A must not change the state of movie C.

`beginOpen` and `close` are legal from every state. Other changes have to match the edges in `legal`. An illegal edge is ignored. The state stays where it was.

## Buffering

`.buffering` is a session state, not a Boolean beside `.playing`. A stall moves `.playing` or `.paused` to `.buffering`. Recovery moves it back. The end of the movie moves the session to `.ended`. `playing` and `buffering` are derived from the state and are never both true. An index that fails eight times, or a malformed index, moves the session to `.failed`.

## Cancellation

The open that creates an `HTTPByteSource` passes that generation's `CancelToken` in before the length probe. Cancelling the token cancels the in-flight tasks, including HEAD. A read of the token pointer takes the source lock. `attach` replaces it under that same lock.


## Active chain versus cache

The Matroska cache remembers clusters that have been parsed. The active chain is the clusters playback is walking right now. `samples(for:)` and `sample(track:at:)` read the chain only. A cluster left in the cache by a later seek is not the next frame.

A seek, including a seek onto a cluster that is already cached, replaces the chain with that one cluster and sets the frontier to the first byte after it. `indexAhead` appends the next cluster in the file. It does not jump to some other cached cluster.

The chain is not evicted. Cached clusters outside the chain are. The cap is 96.

## Frontier

The frontier is the file offset where the next cluster, if there is one, begins. It is the end of the last cluster in the active chain. It is not "the furthest byte we have ever looked at".

## Cues

A cue stores a cluster file offset. `index(covering:)` reads that cluster and does not walk the clusters before it. The same cue twice does not read the file again.

## No cues

The walk starts at the active frontier and continues until the requested time is inside the chain, the segment ends, or 50,000 clusters have been examined. It does not stop at a fixed small number.

## Retry

`.retry` means the read failed and the frontier did not move. The player waits, backs off, and tries the same position. After eight failures it becomes a failure state. `.endOfFile` is the only "there is nothing after this" result.

## Sample ownership

Sample records hold an offset and a size. The picture bytes stay in the source until a read. The active sample array is appended to. A frame request indexes that array. It does not rebuild it.

## Queues

Published player state is written on the main queue. Sample enqueue runs on `cinecore.samples`, which is the queue passed to `requestMediaDataWhenReady`. That queue checks the feed generation before it writes a cursor. A block that hops back to main checks the generation again before it publishes.

## Close

`close` cancels the token, cancels HTTP tasks, stops sample requests, flushes both renderers, drops the media and the formats, and sets the session to idle. A callback that was already queued sees the new generation and returns.
