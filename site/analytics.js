// PostHog — product analytics, web analytics, autocapture + session replay
// for haynoi.com. Single source loaded by every page.
!function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init Ie Ts Ms Ee Es Rs capture Ge calculateEventProperties Os register register_once register_for_session unregister unregister_for_session Ps getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSurveysLoaded onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey canRenderSurveyAsync identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty Ds Fs createPersonProfile Ls Ws opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing Cs debug I As getPageViewId captureTraceFeedback captureTraceMetric".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);

// Privacy gate, ahead of any network request. The PostHog stub only fetches
// array.js from inside init(), so nothing leaves the browser when we skip it.
//
// Honoured: Do Not Track, Global Privacy Control, and an explicit opt-out the
// visitor can set themselves with ?analytics=off (remembered; ?analytics=on
// undoes it).
var OPT_OUT_KEY = "haynoi_analytics_opt_out";

function readParam(name) {
  try { return new URLSearchParams(location.search).get(name); } catch (e) { return null; }
}

function store(key, value) {
  try { value === null ? localStorage.removeItem(key) : localStorage.setItem(key, value); } catch (e) {}
}

function stored(key) {
  try { return localStorage.getItem(key); } catch (e) { return null; }
}

var choice = readParam("analytics");
if (choice === "off") store(OPT_OUT_KEY, "1");
if (choice === "on") store(OPT_OUT_KEY, null);

var doNotTrack =
  navigator.doNotTrack === "1" ||
  navigator.doNotTrack === "yes" ||
  window.doNotTrack === "1" ||
  navigator.msDoNotTrack === "1" ||
  navigator.globalPrivacyControl === true;

// Filled in by scripts/deploy-site.sh from HAYNOI_POSTHOG_KEY. A copy that
// was never filled (local preview, a deploy without the key) sends nothing.
var POSTHOG_KEY = "__HAYNOI_POSTHOG_KEY__";

if (POSTHOG_KEY.indexOf("phc_") === 0 && !doNotTrack && stored(OPT_OUT_KEY) !== "1") {
  posthog.init(POSTHOG_KEY, {
    api_host: "/_ph",                // same-origin proxy (site/functions/_ph), survives ad blockers
    ui_host: "https://us.posthog.com",
    defaults: "2025-05-24",          // history-based pageview + pageleave
    person_profiles: "identified_only",
    // Autocapture stays on for click funnels; PostHog does not record what is
    // typed into inputs. Everything here is off entirely under DNT/GPC.
    autocapture: true,
    capture_pageview: true,
    capture_pageleave: true,
    capture_exceptions: true,
  });

  // CTA clicks, named by the button's data-cta. sendBeacon so the event
  // survives the navigation the click starts.
  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest("[data-cta]");
    if (el) posthog.capture(el.getAttribute("data-cta"), { page: location.pathname }, { transport: "sendBeacon" });
  });

  // Verification event — confirms the install is live in PostHog Activity.
  posthog.capture("haynoi_site_view", {
    page: location.pathname,
    referrer: document.referrer || null,
  });
}

// Affitor partner tracker (program 1081) loads as a static <script> tag in
// each page's <head> — captures ?aff= landings into first-party cookies on
// .haynoi.com. Static tag (not injected here) so it loads early and is
// visible to Affitor's install crawler.
