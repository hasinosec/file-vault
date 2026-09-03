// File Vault's whole first version lives in this one file so it is easy to read.
// It intentionally uses only Node.js built-in modules: no package installation is needed.

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
// AWS library used to store File Vault uploads in S3.
const {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand
} = require('@aws-sdk/client-s3');
const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { Pool } = require('pg');

const PORT = process.env.PORT || 3000;
const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, 'data');
const UPLOAD_DIR = path.join(ROOT, 'uploads');
const DB_FILE = path.join(DATA_DIR, 'database.json');
const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5 MB: enough for learning, safe for a small server.
// These values come from the environment, not hard-coded secret credentials.
const S3_BUCKET = process.env.S3_BUCKET;
const AWS_REGION = process.env.AWS_REGION || 'us-east-1';
const DATABASE_HOST = process.env.DATABASE_HOST;
const DATABASE_NAME = process.env.DATABASE_NAME || 'filevault';
const DATABASE_SECRET_ARN = process.env.DATABASE_SECRET_ARN;
const USE_POSTGRES = Boolean(DATABASE_HOST || DATABASE_SECRET_ARN);

// On EC2, the AWS SDK receives short-lived credentials from the attached IAM role.
const s3 = new S3Client({ region: AWS_REGION });
const secrets = new SecretsManagerClient({ region: AWS_REGION });
let pool;

if (!S3_BUCKET) {
  throw new Error('S3_BUCKET environment variable is required.');
}
if (USE_POSTGRES && (!DATABASE_HOST || !DATABASE_SECRET_ARN)) {
  throw new Error('DATABASE_HOST and DATABASE_SECRET_ARN must be set together.');
}
const sessions = new Map(); // Temporary login sessions; a production app would use Redis or a database.

async function setup() {
  if (USE_POSTGRES) return setupPostgres();

  await fsp.mkdir(DATA_DIR, { recursive: true });
  await fsp.mkdir(UPLOAD_DIR, { recursive: true });
  // The JSON file acts as our tiny local database until we move to AWS RDS/PostgreSQL.
  if (!fs.existsSync(DB_FILE)) await fsp.writeFile(DB_FILE, JSON.stringify({ users: [], files: [] }, null, 2));
}

async function setupPostgres() {
  // AWS keeps the RDS password in Secrets Manager; EC2 reads it through its IAM role.
  const result = await secrets.send(new GetSecretValueCommand({ SecretId: DATABASE_SECRET_ARN }));
  const credentials = JSON.parse(result.SecretString);

  pool = new Pool({
    host: DATABASE_HOST,
    port: 5432,
    database: DATABASE_NAME,
    user: credentials.username,
    password: credentials.password
  });

  // Create the starter schema automatically on an empty learning database.
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id UUID PRIMARY KEY,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS files (
      id UUID PRIMARY KEY,
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      original_name TEXT NOT NULL,
      stored_name TEXT NOT NULL,
      size INTEGER NOT NULL,
      uploaded_at TIMESTAMPTZ NOT NULL
    );
  `);
}

async function readDb() {
  if (!USE_POSTGRES) return JSON.parse(await fsp.readFile(DB_FILE, 'utf8'));

  const users = await pool.query('SELECT id, email, password_hash FROM users ORDER BY email');
  const files = await pool.query('SELECT id, user_id, original_name, stored_name, size, uploaded_at FROM files ORDER BY uploaded_at');

  return {
    users: users.rows.map(row => ({ id: row.id, email: row.email, passwordHash: row.password_hash })),
    files: files.rows.map(row => ({
      id: row.id,
      userId: row.user_id,
      originalName: row.original_name,
      storedName: row.stored_name,
      size: row.size,
      uploadedAt: row.uploaded_at.toISOString()
    }))
  };
}

async function writeDb(db) {
  if (!USE_POSTGRES) return fsp.writeFile(DB_FILE, JSON.stringify(db, null, 2));

  // Simple starter implementation: rewrite the small learning dataset in one transaction.
  // A production app would use focused INSERT/UPDATE/DELETE queries instead.
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('DELETE FROM files');
    await client.query('DELETE FROM users');
    for (const user of db.users) {
      await client.query('INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)', [user.id, user.email, user.passwordHash]);
    }
    for (const file of db.files) {
      await client.query('INSERT INTO files (id, user_id, original_name, stored_name, size, uploaded_at) VALUES ($1, $2, $3, $4, $5, $6)', [file.id, file.userId, file.originalName, file.storedName, file.size, file.uploadedAt]);
    }
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

function send(res, status, body, type = 'text/html; charset=utf-8', headers = {}) {
  res.writeHead(status, { 'Content-Type': type, ...headers });
  res.end(body);
}
function redirect(res, location) { send(res, 302, '', 'text/plain', { Location: location }); }
function escapeHtml(value = '') {
  return String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
}
function parseCookies(req) {
  return Object.fromEntries((req.headers.cookie || '').split(';').filter(Boolean).map(item => {
    const index = item.indexOf('='); return [item.slice(0, index).trim(), decodeURIComponent(item.slice(index + 1))];
  }));
}
function currentUser(req) { return sessions.get(parseCookies(req).session); }
function setSession(res, user) {
  const token = crypto.randomBytes(32).toString('hex');
  sessions.set(token, user);
  res.setHeader('Set-Cookie', `session=${token}; HttpOnly; SameSite=Lax; Path=/`);
}
function clearSession(req, res) { sessions.delete(parseCookies(req).session); res.setHeader('Set-Cookie', 'session=; HttpOnly; Max-Age=0; Path=/'); }
function readBody(req) {
  return new Promise((resolve, reject) => {
    const parts = [];
    req.on('data', part => { parts.push(part); if (Buffer.concat(parts).length > MAX_FILE_SIZE + 1024 * 100) reject(new Error('Upload is too large.')); });
    req.on('end', () => resolve(Buffer.concat(parts)));
    req.on('error', reject);
  });
}
function passwordHash(password, salt = crypto.randomBytes(16).toString('hex')) {
  // scrypt makes stolen passwords much harder to crack than plain text passwords.
  return new Promise((resolve, reject) => crypto.scrypt(password, salt, 64, (error, hash) => error ? reject(error) : resolve(`${salt}:${hash.toString('hex')}`)));
}
async function passwordMatches(password, savedHash) {
  const [salt, hex] = savedHash.split(':');
  const newHash = await passwordHash(password, salt);
  return crypto.timingSafeEqual(Buffer.from(newHash.split(':')[1], 'hex'), Buffer.from(hex, 'hex'));
}
function parseForm(body) { return Object.fromEntries(new URLSearchParams(body.toString('utf8'))); }
function layout(title, content, user) {
  const nav = user
    ? `<a href="/dashboard">Dashboard</a><form action="/logout" method="post"><button>Log out</button></form>`
    : `<a href="/login">Log in</a><a class="button" href="/signup">Create account</a>`;
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${title} · File Vault</title><style>
  *{box-sizing:border-box} body{margin:0;background:#f4f7fb;color:#172033;font:16px system-ui,sans-serif} nav{height:68px;background:#172033;color:white;display:flex;align-items:center;padding:0 max(24px,calc((100% - 960px)/2));gap:20px} nav .brand{font-size:20px;font-weight:800;margin-right:auto} nav a{color:white;text-decoration:none} nav form{margin:0}.wrap{max-width:960px;margin:56px auto;padding:0 24px}.card{background:white;border-radius:14px;padding:28px;box-shadow:0 4px 20px #17203315;margin-bottom:20px}h1{margin-top:0}input{display:block;width:100%;margin:8px 0 18px;padding:12px;border:1px solid #c8d1e0;border-radius:8px;font:inherit}button,.button{border:0;border-radius:8px;background:#2563eb;color:white;padding:11px 16px;font:inherit;font-weight:700;cursor:pointer;text-decoration:none;display:inline-block}.danger{background:#dc2626}.muted{color:#667085}.notice{padding:12px;border-radius:8px;background:#dbeafe;color:#1e40af}table{width:100%;border-collapse:collapse}td,th{padding:13px 8px;border-bottom:1px solid #e5e7eb;text-align:left}td form{display:inline}.hero{font-size:20px;line-height:1.6}</style></head><body><nav><span class="brand">🔐 File Vault</span>${nav}</nav><main class="wrap">${content}</main></body></html>`;
}
function message(req) { return new URL(req.url, `http://${req.headers.host}`).searchParams.get('message'); }

async function handleUpload(req, res, user) {
  const contentType = req.headers['content-type'] || '';
  const boundary = contentType.match(/boundary=(.+)$/)?.[1];
  if (!boundary) return redirect(res, '/dashboard?message=Please choose a file.');
  const body = await readBody(req);
  // A browser form sends multipart data. This small parser extracts its one "file" field.
  const marker = Buffer.from(`--${boundary}`);
  const chunks = [];
  let position = body.indexOf(marker) + marker.length;
  while (position < body.length) {
    const next = body.indexOf(marker, position); if (next === -1) break;
    chunks.push(body.subarray(position, next)); position = next + marker.length;
  }
  const filePart = chunks.find(chunk => chunk.includes(Buffer.from('name="file"')));
  if (!filePart) return redirect(res, '/dashboard?message=Please choose a file.');
  const separator = Buffer.from('\r\n\r\n'); const headerEnd = filePart.indexOf(separator);
  const headers = filePart.subarray(0, headerEnd).toString();
  const originalName = headers.match(/filename="([^\"]*)"/)?.[1] || '';
  let content = filePart.subarray(headerEnd + separator.length);
  if (content.subarray(-2).toString() === '\r\n') content = content.subarray(0, -2);
  if (!originalName || !content.length) return redirect(res, '/dashboard?message=Please choose a file.');
  if (content.length > MAX_FILE_SIZE) return redirect(res, '/dashboard?message=Files must be 5 MB or smaller.');
  // Never use a visitor's file name as a server file path—create our own safe ID instead.
  const id = crypto.randomUUID();
  // Group each user's S3 objects under a private-looking prefix.
  const storedName = `${user.id}/${id}`;
  // Upload the file bytes to the private S3 bucket.
  await s3.send(new PutObjectCommand({
    Bucket: S3_BUCKET,
    Key: storedName,
    Body: content
  }));
  const db = await readDb();
  db.files.push({ id, userId: user.id, originalName: path.basename(originalName), storedName, size: content.length, uploadedAt: new Date().toISOString() });
  await writeDb(db);
  redirect(res, '/dashboard?message=File uploaded successfully.');
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`); const user = currentUser(req);
    if (req.method === 'GET' && url.pathname === '/') return send(res, 200, layout('Welcome', `<section class="card"><h1>Your private space for important files.</h1><p class="hero">File Vault is a learning project: sign in, upload a file, and manage it from one dashboard.</p><p><a class="button" href="/signup">Create your account</a></p></section>`, user));
    if (req.method === 'GET' && url.pathname === '/signup') return send(res, 200, layout('Create account', `<section class="card"><h1>Create account</h1><form action="/signup" method="post"><label>Email<input required type="email" name="email"></label><label>Password <span class="muted">(at least 8 characters)</span><input required minlength="8" type="password" name="password"></label><button>Create account</button></form></section>`, user));
    if (req.method === 'POST' && url.pathname === '/signup') { const { email, password } = parseForm(await readBody(req)); const db = await readDb(); if (!email || !password || password.length < 8) return redirect(res, '/signup?message=Use a valid email and an 8-character password.'); if (db.users.some(item => item.email === email.toLowerCase())) return redirect(res, '/signup?message=That email is already registered.'); const newUser = { id: crypto.randomUUID(), email: email.toLowerCase(), passwordHash: await passwordHash(password) }; db.users.push(newUser); await writeDb(db); setSession(res, { id: newUser.id, email: newUser.email }); return redirect(res, '/dashboard'); }
    if (req.method === 'GET' && url.pathname === '/login') return send(res, 200, layout('Log in', `<section class="card"><h1>Log in</h1><form action="/login" method="post"><label>Email<input required type="email" name="email"></label><label>Password<input required type="password" name="password"></label><button>Log in</button></form></section>`, user));
    if (req.method === 'POST' && url.pathname === '/login') { const { email, password } = parseForm(await readBody(req)); const db = await readDb(); const found = db.users.find(item => item.email === (email || '').toLowerCase()); if (!found || !await passwordMatches(password || '', found.passwordHash)) return redirect(res, '/login?message=Email or password is incorrect.'); setSession(res, { id: found.id, email: found.email }); return redirect(res, '/dashboard'); }
    if (req.method === 'POST' && url.pathname === '/logout') { clearSession(req, res); return redirect(res, '/'); }
    if (!user) return redirect(res, '/login?message=Please log in first.');
    if (req.method === 'GET' && url.pathname === '/dashboard') { const db = await readDb(); const files = db.files.filter(item => item.userId === user.id); const rows = files.length ? files.map(file => `<tr><td>${escapeHtml(file.originalName)}</td><td>${(file.size / 1024).toFixed(1)} KB</td><td>${new Date(file.uploadedAt).toLocaleString()}</td><td><a href="/files/${file.id}/download">Download</a> <form action="/files/${file.id}/delete" method="post"><button class="danger">Delete</button></form></td></tr>`).join('') : '<tr><td colspan="4" class="muted">No files yet—upload your first one above.</td></tr>'; const note = message(req) ? `<p class="notice">${escapeHtml(message(req))}</p>` : ''; return send(res, 200, layout('Dashboard', `<section class="card"><h1>Welcome, ${escapeHtml(user.email)}</h1>${note}<form action="/upload" method="post" enctype="multipart/form-data"><label>Select a file (maximum 5 MB)<input required type="file" name="file"></label><button>Upload file</button></form></section><section class="card"><h2>Your files</h2><table><thead><tr><th>Name</th><th>Size</th><th>Uploaded</th><th>Actions</th></tr></thead><tbody>${rows}</tbody></table></section>`, user)); }
    if (req.method === 'POST' && url.pathname === '/upload') return handleUpload(req, res, user);
    const match = url.pathname.match(/^\/files\/([\w-]+)\/(download|delete)$/);
    if (match) { const [, id, action] = match; const db = await readDb(); const file = db.files.find(item => item.id === id && item.userId === user.id); if (!file) return send(res, 404, layout('Not found', '<section class="card"><h1>File not found</h1></section>', user)); if (action === 'download' && req.method === 'GET') { // Read the file from S3, then send it to the logged-in owner.
      const object = await s3.send(new GetObjectCommand({ Bucket: S3_BUCKET, Key: file.storedName }));
      const content = Buffer.from(await object.Body.transformToByteArray());
      return send(res, 200, content, object.ContentType || 'application/octet-stream', { 'Content-Disposition': `attachment; filename="${file.originalName.replace(/["\\]/g, '')}"` });
    } if (action === 'delete' && req.method === 'POST') { // Versioning means S3 keeps an older recoverable version after deletion.
      await s3.send(new DeleteObjectCommand({ Bucket: S3_BUCKET, Key: file.storedName }));
      db.files = db.files.filter(item => item.id !== id); await writeDb(db); return redirect(res, '/dashboard?message=File deleted.');
    } }
    send(res, 404, layout('Not found', '<section class="card"><h1>Page not found</h1></section>', user));
  } catch (error) { console.error(error); send(res, 500, 'Something went wrong. Check the terminal for details.', 'text/plain'); }
});

setup().then(() => server.listen(PORT, () => console.log(`File Vault is running at http://localhost:${PORT}`)));
