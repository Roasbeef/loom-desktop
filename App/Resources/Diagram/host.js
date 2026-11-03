// The parent of Loom's isolated Mermaid frame, in place of the web view's
// session page. It accepts a message only from its own frame's window, since
// the frame's opaque origin is the string "null" and names nothing, and it
// relays the frame's fixed replies to the app. The app sends each request
// through render(), which waits for the frame's ready message.
"use strict";

const frame = document.getElementById("frame");
const replyLimit = 12512;
let isReady = false;
let waiting = null;

window.addEventListener("message", (event) => {
  if (event.source !== frame.contentWindow) return;
  if (typeof event.data !== "string" || event.data.length > replyLimit) return;

  let reply;
  try {
    reply = JSON.parse(event.data);
  } catch {
    return;
  }
  if (reply === null || typeof reply.kind !== "string") return;

  if (reply.kind === "ready") {
    isReady = true;
    if (waiting !== null) {
      frame.contentWindow.postMessage(waiting, "*");
      waiting = null;
    }
  }
  window.webkit.messageHandlers.diagram.postMessage(event.data);
});

// Takes the request as the JSON string the frame expects. Only the newest
// request waits for the frame; an older one would only be superseded.
window.render = (request) => {
  if (isReady) {
    frame.contentWindow.postMessage(request, "*");
  } else {
    waiting = request;
  }
};
