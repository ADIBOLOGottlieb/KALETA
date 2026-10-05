/**
 * Cartes : proxy serveur avec cache pour l'adresse d'une position (Nominatim) et l'itinéraire (OSRM).
 * L'app n'appelle plus ces services publics directement : un seul User-Agent identifié, au plus
 * 1 requête/s vers Nominatim (règle d'usage), et des réponses en cache pour tous les appareils.
 *
 *  GET /api/geo/reverse?lat=&lng=            → { address } (null si inconnue ou service indisponible)
 *  GET /api/geo/route?from=lat,lng&to=lat,lng → { distance_m, duration_s, points: [[lat, lng], ...] } ou 502
 *
 * fetch natif (Node 24) avec AbortSignal.timeout ; URL et fetch injectables pour les tests.
 */
const express = require('express');
const { requireAuth } = require('./auth');
const { log } = require('./logger');
const { h, httpError } = require('./payments/util');

const DEFAULT_NOMINATIM_URL = 'https://nominatim.openstreetmap.org';
const DEFAULT_OSRM_URL = 'https://router.project-osrm.org';
const TIMEOUT_MS = 8000;

/** Cache mémoire à taille bornée (le plus ancien sort en premier) avec durée de vie. */
class TtlCache {
  constructor(max, ttlMs, now = Date.now) {
    this.max = max;
    this.ttlMs = ttlMs;
    this.now = now;
    this.map = new Map();
  }

  get(key) {
    const e = this.map.get(key);
    if (!e) return undefined;
    if (e.expires <= this.now()) {
      this.map.delete(key);
      return undefined;
    }
    // Remis en fin de file : récemment utilisé.
    this.map.delete(key);
    this.map.set(key, e);
    return e.value;
  }

  set(key, value) {
    this.map.delete(key);
    this.map.set(key, { value, expires: this.now() + this.ttlMs });
    while (this.map.size > this.max) this.map.delete(this.map.keys().next().value);
  }

  get size() {
    return this.map.size;
  }
}

/** Nombre → coordonnée valide ou null. */
function coord(v, max) {
  if (v === undefined || v === null || (typeof v === 'string' && v.trim() === '')) return null;
  const n = Number(v);
  return Number.isFinite(n) && Math.abs(n) <= max ? n : null;
}

/** « lat,lng » → { lat, lng } ou null. */
function parsePair(text) {
  if (typeof text !== 'string') return null;
  const parts = text.split(',');
  if (parts.length !== 2) return null;
  const lat = coord(parts[0], 90);
  const lng = coord(parts[1], 180);
  return lat === null || lng === null ? null : { lat, lng };
}

/** Clé de cache : coordonnées arrondies à 4 décimales (≈ 11 m). */
const key4 = (p) => `${p.lat.toFixed(4)},${p.lng.toFixed(4)}`;

/** Adresse courte « rue, quartier, ville » à partir de la réponse Nominatim (repli : display_name). */
function shortAddress(data) {
  const a = data?.address || {};
  const street = [a.house_number, a.road || a.pedestrian || a.footway].filter(Boolean).join(' ');
  const area = a.neighbourhood || a.suburb || a.quarter || a.village || a.hamlet;
  const city = a.city || a.town || a.municipality || a.county;
  const parts = [...new Set([street, area, city].filter(Boolean))];
  if (parts.length >= 2) return parts.join(', ');
  return typeof data?.display_name === 'string' && data.display_name ? data.display_name.slice(0, 200) : parts[0] || null;
}

/**
 * Service géographique (injectable pour les tests).
 * @param {{ fetch?, nominatimUrl?, osrmUrl?, userAgent?, minIntervalMs?, now? }} opts
 */
function createGeoService(opts = {}) {
  const fetchFn = opts.fetch || ((...a) => fetch(...a));
  const nominatimUrl = String(opts.nominatimUrl || process.env.NOMINATIM_URL || DEFAULT_NOMINATIM_URL).replace(/\/+$/, '');
  const osrmUrl = String(opts.osrmUrl || process.env.OSRM_URL || DEFAULT_OSRM_URL).replace(/\/+$/, '');
  const publicUrl = (process.env.PUBLIC_URL || '').trim();
  const userAgent = opts.userAgent || `Kaleta/1.0${publicUrl ? ` (+${publicUrl})` : ''}`;
  const minIntervalMs = opts.minIntervalMs ?? 1000;
  const now = opts.now || Date.now;

  const addressCache = new TtlCache(1000, 24 * 60 * 60 * 1000, now);
  const routeCache = new TtlCache(500, 10 * 60 * 1000, now);
  const inflight = new Map();

  // File d'attente Nominatim : au plus une requête par seconde (toutes requêtes confondues).
  let queue = Promise.resolve();
  let lastStart = 0;
  function throttled(task) {
    const run = queue.then(async () => {
      const wait = lastStart + minIntervalMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      lastStart = Date.now();
      return task();
    });
    queue = run.catch(() => {});
    return run;
  }

  /** Une seule requête réseau à la fois par clé (plusieurs appareils demandent souvent le même point). */
  function once(k, fn) {
    if (inflight.has(k)) return inflight.get(k);
    const p = fn().finally(() => inflight.delete(k));
    inflight.set(k, p);
    return p;
  }

  async function getJson(url) {
    const res = await fetchFn(url, {
      headers: { 'User-Agent': userAgent, Accept: 'application/json', 'Accept-Language': 'fr' },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json();
  }

  /** Adresse d'une position ; null si inconnue ou service indisponible (jamais d'exception). */
  async function reverse(point) {
    const k = key4(point);
    const cached = addressCache.get(k);
    if (cached !== undefined) return cached;
    return once(`rev:${k}`, async () => {
      try {
        const [lat, lng] = k.split(',');
        const url = `${nominatimUrl}/reverse?format=jsonv2&lat=${lat}&lon=${lng}&zoom=18&addressdetails=1&accept-language=fr`;
        const data = await throttled(() => getJson(url));
        const address = data && !data.error ? shortAddress(data) : null;
        addressCache.set(k, address);
        return address;
      } catch (err) {
        // Erreur réseau : pas de mise en cache, l'appel suivant réessaie.
        log.warn('géocodage inverse indisponible', { error: err.message });
        return null;
      }
    });
  }

  /** Itinéraire en voiture ; lève une erreur 502 si OSRM ne répond pas correctement. */
  async function route(from, to) {
    const k = `${key4(from)};${key4(to)}`;
    const cached = routeCache.get(k);
    if (cached !== undefined) return cached;
    return once(`route:${k}`, async () => {
      const [a, b] = [from, to].map((p) => key4(p).split(',').reverse().join(',')); // OSRM : lng,lat
      const url = `${osrmUrl}/route/v1/driving/${a};${b}?overview=full&geometries=geojson`;
      let data;
      try {
        data = await getJson(url);
      } catch (err) {
        log.warn('itinéraire indisponible', { error: err.message });
        throw httpError(502, 'Itinéraire indisponible pour le moment');
      }
      const r = data?.code === 'Ok' ? data.routes?.[0] : null;
      const coords = r?.geometry?.coordinates;
      if (!r || !Array.isArray(coords)) throw httpError(502, 'Aucun itinéraire trouvé');
      const result = {
        distance_m: Math.round(Number(r.distance) || 0),
        duration_s: Math.round(Number(r.duration) || 0),
        points: coords.filter((c) => Array.isArray(c) && c.length >= 2).map(([lng, lat]) => [lat, lng]),
      };
      routeCache.set(k, result);
      return result;
    });
  }

  return { reverse, route, addressCache, routeCache, userAgent };
}

/** Routes /api/geo/* (connexion requise). */
function createGeoRouter(service = createGeoService()) {
  const router = express.Router();

  router.get('/api/geo/reverse', requireAuth, h(async (req, res) => {
    const lat = coord(req.query.lat, 90);
    const lng = coord(req.query.lng, 180);
    if (lat === null || lng === null) throw httpError(400, 'Position invalide');
    res.json({ address: await service.reverse({ lat, lng }) });
  }));

  router.get('/api/geo/route', requireAuth, h(async (req, res) => {
    const from = parsePair(req.query.from);
    const to = parsePair(req.query.to);
    if (!from || !to) throw httpError(400, 'Positions invalides (from=lat,lng et to=lat,lng)');
    res.json(await service.route(from, to));
  }));

  return router;
}

module.exports = { createGeoService, createGeoRouter, TtlCache, parsePair, shortAddress };
