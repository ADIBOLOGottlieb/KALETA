// Sauvegarde de la base SQLite et des photos (uploads/) dans un dépôt GitHub privé.
// Hébergement gratuit (Render) : le disque est effacé à chaque redéploiement / réveil. Au démarrage,
// start.js restaure la dernière sauvegarde si la base locale est absente ou vide, puis ce module
// envoie un instantané cohérent (VACUUM INTO) quand quelque chose a changé.
// Aucune dépendance : fetch natif de Node + API « git data » de GitHub (blobs, trees, commits, refs),
// ce qui gère les fichiers de plus de 1 Mo et fait un seul commit par sauvegarde (= historique).
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { DatabaseSync } = require('node:sqlite');

const DEFAULT_DB_PATH = path.join(__dirname, '..', 'eza_zozo.db');
const DEFAULT_UPLOADS_DIR = path.join(__dirname, '..', 'uploads');
const DB_REMOTE_NAME = 'eza_zozo.db';
const MAX_FILE_BYTES = 90 * 1024 * 1024; // GitHub refuse les fichiers > 100 Mo.

class GitHubError extends Error {
  constructor(message, status, retryAfterMs = 0) {
    super(message);
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

/** Configuration lue dans l'environnement ; null si la sauvegarde n'est pas configurée. */
function configFromEnv(env = process.env, log = null) {
  const rawRepo = (env.BACKUP_GITHUB_REPO || '').trim();
  const token = (env.BACKUP_GITHUB_TOKEN || '').trim();
  if (!rawRepo && !token) return null;
  const warn = (msg) => (log ? log.warn(msg) : console.warn(msg));
  if (!rawRepo || !token) {
    warn(`sauvegarde désactivée : ${rawRepo ? 'BACKUP_GITHUB_TOKEN' : 'BACKUP_GITHUB_REPO'} manquant`);
    return null;
  }
  // Accepte « propriétaire/dépôt » ou l'adresse https://github.com/propriétaire/dépôt(.git).
  const repo = rawRepo.replace(/^https?:\/\/github\.com\//i, '').replace(/\.git$/i, '').replace(/\/+$/, '');
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) {
    warn('sauvegarde désactivée : BACKUP_GITHUB_REPO doit être de la forme propriétaire/dépôt');
    return null;
  }
  const num = (v, def, min) => {
    const n = Number(v);
    return Number.isFinite(n) && n >= min ? n : def;
  };
  return {
    repo,
    token,
    branch: (env.BACKUP_GITHUB_BRANCH || 'main').trim() || 'main',
    prefix: (env.BACKUP_PATH ?? 'ezazozo').trim().replace(/^\/+|\/+$/g, ''),
    apiBase: (env.BACKUP_GITHUB_API_URL || 'https://api.github.com').replace(/\/+$/, ''),
    dbPath: env.DB_PATH || DEFAULT_DB_PATH,
    uploadsDir: DEFAULT_UPLOADS_DIR,
    intervalMs: num(env.BACKUP_INTERVAL_SECONDS, 60, 1) * 1000,
    periodicMs: 15 * 60 * 1000,
    maxCommits: num(env.BACKUP_MAX_COMMITS, 1000, 10),
  };
}

/** Empreinte « blob » de git (sha1 de « blob <taille>\0<contenu> ») : identique à celle de GitHub. */
function gitBlobSha(buf) {
  return crypto.createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex');
}

/**
 * Empreinte du contenu d'une base, sans les compteurs d'en-tête que chaque VACUUM incrémente
 * (compteur de modifications, cookie de schéma, version SQLite) : une base restaurée puis
 * ré-instantanée sans changement n'est pas renvoyée.
 */
function dbContentHash(buf) {
  const copy = Buffer.from(buf);
  if (copy.length >= 100) {
    copy.fill(0, 24, 28);
    copy.fill(0, 40, 44);
    copy.fill(0, 92, 100);
  }
  return crypto.createHash('sha256').update(copy).digest('hex');
}

/** Base absente, de taille nulle, ou sans aucune table. Une base illisible n'est PAS vide (on n'y touche pas). */
function isLocalDbEmpty(dbPath) {
  const size = (p) => {
    try {
      return fs.statSync(p).size;
    } catch {
      return -1;
    }
  };
  const main = size(dbPath);
  const wal = size(`${dbPath}-wal`);
  if (main < 0 && wal <= 0) return true;
  if (main <= 0 && wal <= 0) return true;
  let conn;
  try {
    conn = new DatabaseSync(dbPath, { readOnly: true });
    return conn.prepare(`SELECT COUNT(*) AS n FROM sqlite_master WHERE type = 'table'`).get().n === 0;
  } catch {
    return false;
  } finally {
    try {
      conn?.close();
    } catch {}
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function createBackup(cfg, { log = require('./logger').log, alert = null, retryBaseMs = 30000, restoreDelaysMs = [2000, 5000] } = {}) {
  const prefixed = (p) => (cfg.prefix ? `${cfg.prefix}/${p}` : p);
  const dbRemote = prefixed(DB_REMOTE_NAME);
  const uploadsRemote = prefixed('uploads/');
  const branchPath = cfg.branch.split('/').map(encodeURIComponent).join('/');
  // Le jeton ne doit jamais apparaître dans un journal, même dans un message d'erreur.
  const clean = (s) => String(s ?? '').split(cfg.token).join('***');
  const L = {
    info: (m, d) => log.info(clean(m), d),
    warn: (m, d) => log.warn(clean(m), d),
    error: (m, d) => log.error(clean(m), d),
  };

  const state = {
    known: null, // chemin distant → sha du blob (dernier état connu du dépôt)
    hold: false, // vrai : une sauvegarde distante existe mais n'a pas pu être restaurée → ne pas l'écraser
    holdLoggedAt: 0,
    lastSig: null,
    lastRunAt: 0,
    failures: 0,
    backoffUntil: 0,
    running: null,
    writes: [], // horodatage des requêtes d'écriture (limite secondaire GitHub ≈ 500 / h)
    hashCache: new Map(),
    dbContent: null, // { sha, hash } : contenu (hors compteurs d'en-tête) de la base distante connue
    conn: null,
    timers: [],
    stopped: false,
  };

  // ---------- API GitHub ----------
  async function gh(method, apiPath, { body, raw = false, timeoutMs = 30000 } = {}) {
    const url = `${cfg.apiBase}/repos/${cfg.repo}/${apiPath}`;
    const headers = {
      Authorization: `Bearer ${cfg.token}`,
      Accept: raw ? 'application/vnd.github.raw+json' : 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'kaleta-backup',
    };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (method !== 'GET') state.writes.push(Date.now());
    let res;
    try {
      res = await fetch(url, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      throw new GitHubError(`réseau : ${method} ${apiPath.split('?')[0]} — ${err.cause?.code || err.name || ''} ${err.message}`, 0);
    }
    if (!res.ok) {
      let msg = '';
      try {
        msg = (await res.json()).message || '';
      } catch {}
      let retryAfterMs = 0;
      if (res.status === 403 || res.status === 429) {
        const after = Number(res.headers.get('retry-after'));
        const reset = Number(res.headers.get('x-ratelimit-reset'));
        if (after > 0) retryAfterMs = after * 1000;
        else if (res.headers.get('x-ratelimit-remaining') === '0' && reset > 0) retryAfterMs = Math.max(0, reset * 1000 - Date.now()) + 1000;
      }
      throw new GitHubError(`GitHub ${method} ${apiPath.split('?')[0]} → ${res.status} ${msg}`, res.status, retryAfterMs);
    }
    if (raw) {
      const buf = Buffer.from(await res.arrayBuffer());
      // Si le serveur ignore le format brut, il renvoie du JSON avec le contenu en base64.
      if (/json/i.test(res.headers.get('content-type') || '')) {
        try {
          const j = JSON.parse(buf.toString('utf8'));
          if (j && j.encoding === 'base64' && typeof j.content === 'string') return Buffer.from(j.content, 'base64');
        } catch {}
      }
      return buf;
    }
    return res.status === 204 ? null : res.json();
  }

  /** État distant : { commitSha, treeSha, message, files: Map(chemin → sha) } ou null si aucune sauvegarde. */
  async function fetchRemote() {
    let ref;
    try {
      ref = await gh('GET', `git/ref/heads/${branchPath}`);
    } catch (err) {
      if (err.status === 404 || err.status === 409) return null; // branche absente ou dépôt vide
      throw err;
    }
    const commitSha = ref.object.sha;
    const commit = await gh('GET', `git/commits/${commitSha}`);
    const tree = await gh('GET', `git/trees/${commit.tree.sha}?recursive=1`);
    if (tree.truncated) L.warn('sauvegarde : arborescence du dépôt tronquée par GitHub (trop de fichiers)');
    const files = new Map();
    for (const e of tree.tree || []) {
      if (e.type !== 'blob') continue;
      if (e.path === dbRemote || e.path.startsWith(uploadsRemote)) files.set(e.path, e.sha);
    }
    return { commitSha, treeSha: commit.tree.sha, message: commit.message || '', files };
  }

  // ---------- Restauration ----------
  function safeLocalUpload(remotePath) {
    const rel = remotePath.slice(uploadsRemote.length);
    if (!rel || rel.split('/').some((s) => !s || s === '.' || s === '..' || s.startsWith('.'))) return null;
    const dest = path.resolve(cfg.uploadsDir, ...rel.split('/'));
    const root = path.resolve(cfg.uploadsDir) + path.sep;
    return dest.startsWith(root) ? dest : null;
  }

  async function restoreDb(sha) {
    const buf = await gh('GET', `git/blobs/${sha}`, { raw: true, timeoutMs: 120000 });
    if (gitBlobSha(buf) !== sha) throw new Error('sauvegarde téléchargée incomplète (empreinte différente)');
    if (buf.subarray(0, 16).toString('latin1') !== 'SQLite format 3\0') throw new Error("le fichier sauvegardé n'est pas une base SQLite");
    fs.mkdirSync(path.dirname(path.resolve(cfg.dbPath)), { recursive: true });
    const tmp = `${cfg.dbPath}.restore-${process.pid}`;
    fs.writeFileSync(tmp, buf);
    try {
      const check = new DatabaseSync(tmp, { readOnly: true });
      let ok;
      try {
        ok = check.prepare('PRAGMA quick_check').get();
      } finally {
        check.close();
      }
      if (Object.values(ok)[0] !== 'ok') throw new Error('base sauvegardée corrompue (quick_check)');
      // Dernière vérification juste avant de remplacer : jamais d'écrasement d'une base non vide.
      if (!isLocalDbEmpty(cfg.dbPath)) throw new Error('base locale non vide : restauration annulée');
      for (const f of [`${cfg.dbPath}-wal`, `${cfg.dbPath}-shm`, `${cfg.dbPath}-journal`]) fs.rmSync(f, { force: true });
      fs.rmSync(cfg.dbPath, { force: true });
      fs.renameSync(tmp, cfg.dbPath);
    } finally {
      fs.rmSync(tmp, { force: true });
      for (const f of [`${tmp}-wal`, `${tmp}-shm`]) fs.rmSync(f, { force: true });
    }
    state.dbContent = { sha, hash: dbContentHash(buf) };
    return buf.length;
  }

  /**
   * À appeler AVANT d'ouvrir la base (avant require('./server')). Restaure la base si elle est absente
   * ou vide, et les photos manquantes. Ne lève jamais.
   */
  async function restore() {
    const result = { db: false, uploads: 0, error: null };
    const dbWasEmpty = isLocalDbEmpty(cfg.dbPath);
    let remote;
    const delays = [0, ...restoreDelaysMs];
    for (let i = 0; i < delays.length; i++) {
      if (delays[i]) await sleep(delays[i]);
      try {
        remote = await fetchRemote();
        break;
      } catch (err) {
        result.error = err;
        L.warn(`sauvegarde : lecture du dépôt impossible (essai ${i + 1}/${delays.length}) : ${clean(err.message)}`);
        if (err.status === 401 || err.status === 403 || err.status === 404) break; // inutile d'insister
      }
    }
    if (remote === undefined) {
      if (dbWasEmpty) {
        state.hold = true;
        L.error('sauvegarde : restauration impossible, démarrage sur une base neuve ; envoi suspendu tant que le dépôt est injoignable pour ne pas écraser la sauvegarde existante');
      }
      return result;
    }
    result.error = null;
    if (!remote) {
      state.known = new Map();
      L.info(`sauvegarde : aucune sauvegarde dans ${cfg.repo} (${cfg.branch}), démarrage normal`);
      return result;
    }
    state.known = new Map(remote.files);
    const dbSha = remote.files.get(dbRemote);
    if (dbSha && dbWasEmpty) {
      try {
        const bytes = await restoreDb(dbSha);
        result.db = true;
        L.info('sauvegarde : base restaurée', { octets: bytes, commit: remote.commitSha.slice(0, 7), message: remote.message.split('\n')[0] });
      } catch (err) {
        result.error = err;
        // La sauvegarde distante existe : ne jamais l'écraser par une base neuve.
        if (isLocalDbEmpty(cfg.dbPath)) state.hold = true;
        L.error(`sauvegarde : échec de la restauration de la base : ${clean(err.message)}`);
      }
    } else if (dbSha) {
      L.info('sauvegarde : base locale déjà présente, pas de restauration');
    }
    // Photos : seulement celles qui manquent localement (aucun fichier existant n'est écrasé).
    for (const [remotePath, sha] of remote.files) {
      if (!remotePath.startsWith(uploadsRemote)) continue;
      const dest = safeLocalUpload(remotePath);
      if (!dest || fs.existsSync(dest)) continue;
      try {
        const buf = await gh('GET', `git/blobs/${sha}`, { raw: true, timeoutMs: 60000 });
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.writeFileSync(`${dest}.part`, buf);
        fs.renameSync(`${dest}.part`, dest);
        result.uploads++;
      } catch (err) {
        L.warn(`sauvegarde : photo non restaurée ${remotePath} : ${clean(err.message)}`);
      }
    }
    if (result.uploads) L.info('sauvegarde : photos restaurées', { fichiers: result.uploads });
    return result;
  }

  // ---------- Sauvegarde ----------
  function connection() {
    if (!state.conn) state.conn = new DatabaseSync(cfg.dbPath, { readOnly: true });
    return state.conn;
  }

  function listUploads() {
    const out = [];
    const walk = (dir, rel) => {
      let entries;
      try {
        entries = fs.readdirSync(dir, { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        if (e.name.startsWith('.') || e.name.endsWith('.part')) continue;
        const full = path.join(dir, e.name);
        const r = rel ? `${rel}/${e.name}` : e.name;
        if (e.isDirectory()) walk(full, r);
        else if (e.isFile()) {
          try {
            const st = fs.statSync(full);
            out.push({ rel: r, full, size: st.size, mtimeMs: st.mtimeMs });
          } catch {}
        }
      }
    };
    walk(cfg.uploadsDir, '');
    return out.sort((a, b) => (a.rel < b.rel ? -1 : 1));
  }

  /** Signature bon marché : change dès qu'une autre connexion écrit dans la base ou qu'une photo arrive. */
  function signature() {
    const st = (p) => {
      try {
        const s = fs.statSync(p);
        return `${s.size}:${s.mtimeMs}`;
      } catch {
        return '-';
      }
    };
    let version = '?';
    try {
      version = connection().prepare('PRAGMA data_version').get().data_version;
    } catch {}
    const ups = listUploads().map((u) => `${u.rel}:${u.size}:${u.mtimeMs}`).join('|');
    return `${version}|${st(cfg.dbPath)}|${st(`${cfg.dbPath}-wal`)}|${crypto.createHash('sha1').update(ups).digest('hex')}`;
  }

  /** Instantané cohérent de la base (VACUUM INTO dans un fichier temporaire). */
  function snapshot() {
    const tmp = path.join(os.tmpdir(), `eza-zozo-backup-${process.pid}-${Date.now()}.db`);
    try {
      connection().prepare('VACUUM INTO ?').run(tmp);
      return fs.readFileSync(tmp);
    } finally {
      fs.rmSync(tmp, { force: true });
    }
  }

  function uploadSha(u) {
    const c = state.hashCache.get(u.rel);
    if (c && c.size === u.size && c.mtimeMs === u.mtimeMs) return c.sha;
    const sha = gitBlobSha(fs.readFileSync(u.full));
    state.hashCache.set(u.rel, { size: u.size, mtimeMs: u.mtimeMs, sha });
    return sha;
  }

  function writesLastHour() {
    const limit = Date.now() - 3600 * 1000;
    state.writes = state.writes.filter((t) => t > limit);
    return state.writes.length;
  }

  async function push(changes, remote) {
    const entries = [];
    for (const c of changes) {
      const blob = await gh('POST', 'git/blobs', { body: { content: c.buf.toString('base64'), encoding: 'base64' }, timeoutMs: 120000 });
      if (blob.sha !== c.sha) throw new Error(`empreinte inattendue pour ${c.path}`);
      entries.push({ path: c.path, mode: '100644', type: 'blob', sha: c.sha });
    }
    const n = (Number((remote?.message.match(/n°(\d+)/) || [])[1]) || 0) + 1;
    // Historique limité : au-delà de maxCommits, on repart d'un commit sans parent (les anciens sont oubliés).
    const fresh = !remote || n > cfg.maxCommits;
    const tree = await gh('POST', 'git/trees', { body: remote ? { base_tree: remote.treeSha, tree: entries } : { tree: entries } });
    const number = fresh ? 1 : n;
    const message = `Sauvegarde ${new Date().toISOString().slice(0, 19).replace('T', ' ')} UTC (n°${number})${fresh && remote ? ' — nouvel historique' : ''}`;
    const commit = await gh('POST', 'git/commits', { body: { message, tree: tree.sha, parents: fresh ? [] : [remote.commitSha] } });
    if (remote) await gh('PATCH', `git/refs/heads/${branchPath}`, { body: { sha: commit.sha, force: fresh } });
    else await gh('POST', 'git/refs', { body: { ref: `refs/heads/${cfg.branch}`, sha: commit.sha } });
    return commit.sha;
  }

  /** Dépôt complètement vide : l'API git data refuse (409), on crée un premier fichier via l'API contents. */
  async function initEmptyRepo() {
    const readme = '# Sauvegardes KALETA\n\nDépôt PRIVÉ alimenté automatiquement par le serveur. Ne pas rendre public.\n';
    await gh('PUT', `contents/${prefixed('LISEZMOI.md').split('/').map(encodeURIComponent).join('/')}`, {
      body: { message: 'Initialisation des sauvegardes', content: Buffer.from(readme).toString('base64'), branch: cfg.branch },
    });
  }

  async function doBackup({ final }) {
    if (!final && Date.now() < state.backoffUntil) return { skipped: 'backoff' };
    const sig = signature();
    if (state.known === null || state.hold) {
      const remote = await fetchRemote();
      if (state.hold) {
        if (remote && remote.files.has(dbRemote)) {
          if (Date.now() - state.holdLoggedAt > cfg.periodicMs) {
            state.holdLoggedAt = Date.now();
            const msg = "Sauvegarde suspendue : la sauvegarde GitHub existante n'a pas été restaurée au démarrage. Redémarrez le serveur pour la restaurer (rien n'est envoyé pour ne pas l'écraser).";
            L.error(msg);
            alert?.(msg);
          }
          return { skipped: 'hold' };
        }
        state.hold = false;
      }
      state.known = remote ? new Map(remote.files) : new Map();
    }
    const dbBuf = snapshot();
    const changes = [];
    const dbSha = gitBlobSha(dbBuf);
    const remoteDb = state.known.get(dbRemote);
    const same = remoteDb === dbSha || (state.dbContent && state.dbContent.sha === remoteDb && state.dbContent.hash === dbContentHash(dbBuf));
    if (!same) changes.push({ path: dbRemote, sha: dbSha, buf: dbBuf });
    // Photos : nouvelles ou modifiées, par petits lots (limites d'écriture de GitHub).
    const budget = Math.max(0, 400 - writesLastHour() - 4);
    let pending = 0;
    for (const u of listUploads()) {
      if (u.size > MAX_FILE_BYTES) continue;
      const p = prefixed(`uploads/${u.rel}`);
      let sha;
      try {
        sha = uploadSha(u);
      } catch {
        continue; // fichier supprimé entre-temps
      }
      if (state.known.get(p) === sha) continue;
      if (changes.length >= Math.min(20, budget) && !final) {
        pending++;
        continue;
      }
      changes.push({ path: p, sha, buf: fs.readFileSync(u.full) });
    }
    state.lastRunAt = Date.now();
    if (!changes.length) {
      state.lastSig = pending ? null : sig;
      return { pushed: false, pending };
    }
    if (!final && budget === 0) {
      L.warn("sauvegarde : limite d'écriture GitHub proche, envoi reporté");
      return { skipped: 'budget' };
    }
    let commitSha;
    for (let attempt = 1; ; attempt++) {
      let remote;
      try {
        remote = await fetchRemote();
        commitSha = await push(changes, remote);
        break;
      } catch (err) {
        if (err.status === 409 && attempt === 1 && !remote) {
          await initEmptyRepo();
          continue;
        }
        // Branche avancée entre-temps (autre instance) : on relit et on recommence une fois.
        if (err.status === 422 && attempt === 1) continue;
        throw err;
      }
    }
    for (const c of changes) state.known.set(c.path, c.sha);
    if (changes[0].path === dbRemote) state.dbContent = { sha: dbSha, hash: dbContentHash(dbBuf) };
    state.lastSig = pending ? null : sig;
    const bytes = changes.reduce((s, c) => s + c.buf.length, 0);
    L.info('sauvegarde envoyée', {
      commit: commitSha.slice(0, 7),
      base: changes.some((c) => c.path === dbRemote),
      photos: changes.filter((c) => c.path !== dbRemote).length,
      octets: bytes,
      en_attente: pending,
    });
    return { pushed: true, files: changes.map((c) => c.path), pending, commit: commitSha };
  }

  /** Une passe de sauvegarde. Ne lève jamais ; un seul envoi à la fois. */
  function run({ final = false } = {}) {
    if (state.running) {
      if (!final) return state.running;
      return state.running.then(() => run({ final }));
    }
    state.running = doBackup({ final })
      .then((r) => {
        if (r.pushed !== undefined) {
          if (state.failures) L.info('sauvegarde : de nouveau opérationnelle');
          state.failures = 0;
          state.backoffUntil = 0;
        }
        return r;
      })
      .catch((err) => {
        state.failures++;
        const wait = Math.max(err.retryAfterMs || 0, Math.min(cfg.periodicMs, retryBaseMs * 2 ** (state.failures - 1)));
        state.backoffUntil = Date.now() + wait;
        const msg = `sauvegarde échouée (${state.failures}) : ${clean(err.message)}`;
        if (state.failures >= 3 || err.status === 401) L.error(msg, { nouvel_essai_s: Math.round(wait / 1000) });
        else L.warn(msg, { nouvel_essai_s: Math.round(wait / 1000) });
        if (state.failures === 3 || err.status === 401) {
          alert?.(err.status === 401 ? 'Sauvegarde GitHub refusée : jeton invalide ou expiré (BACKUP_GITHUB_TOKEN).' : 'Sauvegarde GitHub en échec répété : vérifiez le dépôt et le jeton.');
        }
        return { error: clean(err.message) };
      })
      .finally(() => {
        state.running = null;
      });
    return state.running;
  }

  /** Vérifie régulièrement s'il y a eu une écriture (≤ intervalMs) + passe complète toutes les 15 min. */
  function start() {
    const tick = () => {
      if (state.stopped) return;
      let sig = null;
      try {
        sig = signature();
      } catch {}
      if (sig !== state.lastSig || Date.now() - state.lastRunAt >= cfg.periodicMs) run();
    };
    state.timers.push(setInterval(tick, cfg.intervalMs));
    // Première passe peu après le démarrage (base fraîchement migrée / créée).
    state.timers.push(setTimeout(tick, Math.min(5000, cfg.intervalMs)));
    for (const t of state.timers) t.unref?.();
    L.info('sauvegarde GitHub active', { depot: cfg.repo, branche: cfg.branch, dossier: cfg.prefix || '/', intervalle_s: cfg.intervalMs / 1000 });
  }

  /** Arrêt (SIGTERM) : dernière sauvegarde, bornée dans le temps. */
  async function stop({ timeoutMs = 25000 } = {}) {
    state.stopped = true;
    for (const t of state.timers) clearInterval(t);
    state.timers = [];
    let r;
    try {
      r = await Promise.race([run({ final: true }), sleep(timeoutMs).then(() => ({ error: 'délai dépassé' }))]);
    } catch (err) {
      r = { error: clean(err.message) };
    }
    try {
      state.conn?.close();
    } catch {}
    state.conn = null;
    return r;
  }

  return { restore, run, start, stop, state };
}

module.exports = { configFromEnv, createBackup, isLocalDbEmpty, gitBlobSha, dbContentHash, DB_REMOTE_NAME };
