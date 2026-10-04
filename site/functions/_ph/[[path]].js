// Same-origin reverse proxy for PostHog: haynoi.com/_ph/* → PostHog US.
// Ad blockers drop requests to *.posthog.com, not to our own origin.
// /_ph/static/* (SDK, extensions) and /_ph/array/* (remote config) are served by
// the assets host, everything else is ingestion.
export async function onRequest({ request }) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/^\/_ph/, "") || "/";
  const assets = path.startsWith("/static/") || path.startsWith("/array/");
  const host = assets ? "us-assets.i.posthog.com" : "us.i.posthog.com";

  const headers = new Headers(request.headers);
  headers.delete("cookie"); // haynoi.com cookies (Affitor attribution) are not PostHog's business
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) headers.set("x-forwarded-for", ip); // keep visitor geo instead of the edge's

  return fetch(new Request(`https://${host}${path}${url.search}`, {
    method: request.method,
    headers,
    body: ["GET", "HEAD"].includes(request.method) ? undefined : request.body,
    redirect: "manual",
  }));
}
