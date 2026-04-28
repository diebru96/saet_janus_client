# saet janus client
## USAGE

This file explains how to instantiate and use Saet janus WebRTC streaming.
With Flutter there are 2 core dependencies that are janus_client and flutter_web_rtc

## Steps overview

1. Acquire videoproxy configuration
   - Fetch URL, token, STUN/TURN by calling HTTP GET `/videocloud/$deviceId/facile/$mac/info` per FACILE,`/videocloud/$deviceId/hicloud/$mac/info` per

2. Create JanusClient (Only for Flutter with package JanusClient)
   -
   ```dart
   final janusClient = JanusClient(
     transport: RestJanusTransport(url: state.videoproxyInfo?.videoproxyUrl ?? ""),
     withCredentials: true,
     token: state.videoproxyInfo?.videoProxyToken ?? "",
     apiSecret: state.videoproxyInfo?.videoProxyToken ?? "",
     iceServers: [
       RTCIceServer(
         urls: state.videoproxyInfo!.turnServer!.url,
         username: state.videoproxyInfo!.turnServer!.username,
         credential: state.videoproxyInfo!.turnServer!.credential,
       ),
       RTCIceServer(urls: state.videoproxyInfo!.stunServer ?? ""),
     ],
   );
   ```
3. You can either Create janus Session, plugin and ask to watch camId all in one with 
   - HTTP POST a `/janus` con payload:
   ```json
    {"janus":"createwatch","id": "camId", "transaction":"rand","token":"videoProxyToken","apisecret":"videoProxyToken", ""}
    ```
    This post returns sessionId, handleId, streamHeight and streamWidth
    The usage in your dart code is the following
      ```dart
       janusClient.createSessionAndWatchVideo(camNumber);
      ```
   That answers with object JanusSessionPlugin
   ```dart
   class JanusSessionPlugin {
     JanusSession? session;
     JanusPlugin? streamingPlugin;
     JanusPlugin? videomuxPlugin;

     int height = 0;
     int width = 0;
     JanusSessionPlugin({this.session, this.streamingPlugin, this.videomuxPlugin, this.height = 0, this.width = 0});
   }   
   ```
   videoMuxPlugin will always be null when the answer is coming from createSessionAndWatchVideo

    OR

3. Create janus Session
   - HTTP POST a `/janus` con payload:
   ```json
    {"janus":"create","transaction":"rand","token":"videoProxyToken","apisecret":"videoProxyToken"}
    ```
    The Create will answer (in case of success)
    ```json
     {"data":{"id": "$sessionId"}}
    ```
    We will need the `sessionId` to call the attach.

4. Attach janus plugin
    - HTTP POST a `/janus/$sessionId` con payload:
     ```json
        {"janus":"attach","transaction":"rand","apisecret":"videoProxyToken","token":"videoProxyToken","session_id":$sessionId,"plugin":"janus.plugin.streaming"}
     ```
     This call will answer with an `handleId`


5. Concurrently to theese operation we should start a longpolling (in Flutter it is handled by janus_client).
    All the async comunication between videocloud and frontend will be handled by this longpoll (for example we'll receive the jsep here)
    - it consists of a HTTP GET to ... that is performed again and again everytime it receive an answer (N.B. the answer is delayed, so it may take up to 30 sec)

6.  In Flutter we have to listen to the messages coming out of this longpolling and we do that by listening toPlugin messages.
     - Plugin messages: handle `plugindata` and `jsep`. When receiving JSEP:
     - `plugin.handleRemoteJsep(...)`
     - `plugin.createAnswer()` ---> This operation and HandleRemoteJsep are used to complete the P2P connection with the cam.
     - `createAnswer()` will return a `RTCSessionDescription` that we will need to Start the video.

7. We should also listen to remote stream change in order to instantiate our remoteRender
   - Mobile: `plugin.remoteStream` → listen and update `mediaStream` in state (`listenToRemoteStreamMobile()`).
   - Web: `peerConnection.onTrack` → use `event.streams[0]` as `mediaStream` (`listenWebToPeerConnectionOnTrack()`).


8. Watch request: A request to start watching a camera (camId equivale al numero della telecamera che si vuole guardare)
    - HTTP POST a `/janus/$sessionId/$handleId` con payload:
    ```json
     {
       "request": "watch",
       "id": camId,
       "offer_audio": false,
       "offer_video": true,
       "transaction":"rand",
       "token":"videoProxyToken",
       "apisecret":"videoProxyToken"
     }
    ```
    -  After calling this Watch we will start receiving the JSEP throgh the longpolling.

9. As soon as we receive the JSEP we will perform a configure and a start request
    - HTTP POST a `/janus/$sessionId/$handleId` con payload:
    ```json
     {
       "request": "configure", "min_delay": 60, "max_delay": 60,
       "transaction":"rand",
       "token":"videoProxyToken",
       "apisecret":"videoProxyToken"
     }
    - HTTP POST a `/janus/$sessionId/$handleId` con payload:
    ```json
     {
       "request": "start",
       "jsep:": "RTCSessionDescription", --> quello che ritorna la richiesta CreateAnswer
       "offer_audio": false,
       "offer_video": true,
       "transaction":"rand",
       "token":"videoProxyToken",
       "apisecret":"videoProxyToken"
     }

10. Render the stream in Flutter
   - Initialize `RTCVideoRenderer`, set `srcObject` when `mediaStream` changes, and dispose:
   ```dart
   final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
   await _remoteRenderer.initialize();
   _remoteRenderer.srcObject = videoState.mediaStream;
   // on dispose
   _remoteRenderer.dispose();
   ```
   - Use `RTCVideoView(_remoteRenderer)` in the widget tree (see `VideoPanel`).

11. Stop and teardown
   - To stop playback: `plugin.send(data: {"request": "stop"})` (`stopVideo()`). --> this is an HTTP POST exacly like start and watch
   - To fully teardown: `plugin.dispose()` and `session.dispose()` and clear `mediaStream` (`destroy()`). --> They permorm a "destroy" HTTP request.

---
##VIDEO ALARMS VERIFICATIONS
For video-alarms the process is basically the same.
The short way is to use the createwatch call as in 3. 
   ```json
    {"janus":"createwatch","id": "camId", "hash": hash, "sens": sens, "time": time, "transaction":"rand","token":"videoProxyToken","apisecret":"videoProxyToken"}
   ```
 you can call this from your code with
   ```dart
      await janusClient.createSessionAndWatchVideoRecorded(
            state.recordedVideoData!.video,
            state.recordedVideoData!.sens,
            state.recordedVideoData!.time,
          )   
   ```
   That answers with object JanusSessionPlugin that will always have the param videomuxPlugin populated

   ```dart
   class JanusSessionPlugin {
     JanusSession? session;
     JanusPlugin? streamingPlugin;
     JanusPlugin? videomuxPlugin;

     int height = 0;
     int width = 0;
     JanusSessionPlugin({this.session, this.streamingPlugin, this.videomuxPlugin, this.height = 0, this.width = 0});
   }   
   ```
 this call must be used in step 3. The following steps are the same as opening the cam in streaming. 

 Once the video is playing we can send 3 commands through the videomux plugin.
 1.REWIND to restart the video from the beginning
 ```dart
  Future<void> rewindRecordedVideo() async {
    await state.janusVideoState?.videoMuxPlugin?.send(data: {"videomux": "rewind"});
  }
 ```
2.PAUSE
 ```dart
  Future<void> pauseVideo() async {
    await state.janusVideoState?.videoMuxPlugin?.send(data: {"videomux": "pause"});
  }
 ```
3.RESUME
```dart
  Future<void> resumeVideo() async {
    await state.janusVideoState?.videoMuxPlugin?.send(data: {"videomux": "resume"});
  }
```


## Notes and best practices
- Properly initialize and dispose the renderer; call `destroy()` on background/exit.
- Handle session/plugin creation errors and loading/failure states.
- On web, if the video starts muted, force-enable the video track after a short delay (see `listenWebToPeerConnectionOnTrack()`).
