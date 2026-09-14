import os from 'os';
import { createReadStream, statSync } from 'fs';
import { mkdir, writeFile, unlink, rename, readFile } from 'fs/promises';
import { join } from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';

process.removeAllListeners('warning');
const execFileAsync = promisify(execFile);

const REQUIRED_ENV_VARS = [
  'WORKER_SUFFIX',
  'TTS_PORT',
  'API_BASE_URL',
  'WORKER_API_SECRET',
  'WORKER_SESSION_ID',
  'JOB_TYPE',
  'MODEL',
  'POLL_INTERVAL_SECONDS',
  'MAX_EMPTY_POLLS',
  'R2_ACCOUNT_ID',
  'R2_ACCESS_KEY_ID',
  'R2_SECRET_ACCESS_KEY',
  'R2_BUCKET_NAME',
  'R2_CDN_URL'
];

const missing_vars = REQUIRED_ENV_VARS.filter((key) => {
  const val = process.env[key];
  return val === undefined || val === null || val.trim() === '';
});

if (missing_vars.length > 0) {
  console.error(`\x1b[31m[FATAL] Missing required environment variable(s):\n  - ${missing_vars.join('\n  - ')}\x1b[0m`);
  process.exit(1);
}

const WORKER_SUFFIX = process.env.WORKER_SUFFIX;
const TTS_PORT = parseInt(process.env.TTS_PORT, 10);
const TTS_HOST = `http://127.0.0.1:${TTS_PORT}`;
const WORKER_NUM = (WORKER_SUFFIX.match(/\d+/) ? WORKER_SUFFIX.match(/\d+/)[0] : '1').padStart(3, '0');
const TAG = `[ ${WORKER_NUM} ]`;

const STAGING_DIR = `/tmp/fish_worker_${WORKER_SUFFIX}`;
const INPUT_DIR = join(STAGING_DIR, 'input');
const OUTPUT_DIR = join(STAGING_DIR, 'output');

const MACHINE_ID = os.hostname();
const UNIQUE_WORKER_ID = `${MACHINE_ID}-${WORKER_SUFFIX}`;
const WORKER_API_SECRET = process.env.WORKER_API_SECRET;
const WORKER_SESSION_ID = process.env.WORKER_SESSION_ID;

const API_BASE_URL = process.env.API_BASE_URL;
const JOB_TYPE = process.env.JOB_TYPE;
const MODEL_TYPE = process.env.MODEL;
const POLL_INTERVAL_SECONDS = parseInt(process.env.POLL_INTERVAL_SECONDS, 10);
const MAX_EMPTY_POLLS = parseInt(process.env.MAX_EMPTY_POLLS, 10);

const R2_ACCOUNT_ID = process.env.R2_ACCOUNT_ID;
const R2_ACCESS_KEY_ID = process.env.R2_ACCESS_KEY_ID;
const R2_SECRET_ACCESS_KEY = process.env.R2_SECRET_ACCESS_KEY;
const R2_BUCKET_NAME = process.env.R2_BUCKET_NAME;
const R2_CDN_URL = process.env.R2_CDN_URL;

const active_uploads = new Set();
const STATS_FILE = `/tmp/worker_stats_${WORKER_SUFFIX}.json`;
let jobs_processed = 0;
let total_generation_time_sec = 0;

const s3_client = new S3Client({
  region: 'auto',
  endpoint: `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: R2_ACCESS_KEY_ID,
    secretAccessKey: R2_SECRET_ACCESS_KEY,
  },
  requestHandler: {
    requestTimeout: 60000,
    connectionTimeout: 10000,
  }
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const get_api_headers = () => ({
  'worker-auth': WORKER_API_SECRET,
  'x-machine-id': MACHINE_ID,
  'x-worker-id': UNIQUE_WORKER_ID,
  'content-type': 'application/json'
});

const sync_stats_to_disk = async () => {
  try {
    await writeFile(STATS_FILE, JSON.stringify({
      worker: UNIQUE_WORKER_ID,
      jobs_processed,
      total_generation_time_sec: Math.round(total_generation_time_sec * 100) / 100
    }));
  } catch (err) {
    console.error(`\x1b[31m${TAG} Failed to write stats to disk: ${err.message}\x1b[0m`);
  }
};

const poll_for_job = async () => {
  const payload = {
    session_id: WORKER_SESSION_ID,
    worker_id: UNIQUE_WORKER_ID,
    slot: WORKER_SUFFIX,
    job_type: JOB_TYPE,
    model: MODEL_TYPE,
    models: MODEL_TYPE
  };

  try {
    const res = await fetch(`${API_BASE_URL}/v1/worker/get`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(15000)
    });

    const bodyText = await res.text();
    if (!res.ok) {
      console.error(`\x1b[31m${TAG} API Poll HTTP Error ${res.status}: ${bodyText}\x1b[0m`);
      return null;
    }

    let json;
    try {
      json = JSON.parse(bodyText);
    } catch (_) {
      console.error(`\x1b[31m${TAG} Failed to parse API Poll JSON: ${bodyText}\x1b[0m`);
      return null;
    }

    if (!json.success || !json.data) return null;

    return await prepare_job(json.data);
  } catch (err) {
    console.error(`\x1b[31m${TAG} API Poll Network Error: ${err.message}\x1b[0m`);
    return null;
  }
};

const download_file = async (url, target_path) => {
  const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!res.ok) throw new Error(`HTTP ${res.status} downloading ${url}`);

  const buffer = await res.arrayBuffer();
  if (buffer.byteLength < 512) {
    throw new Error(`Downloaded file is corrupt or empty (${buffer.byteLength} bytes)`);
  }

  const temp_path = `${target_path}.tmp_${Date.now()}`;
  await writeFile(temp_path, Buffer.from(buffer));
  await rename(temp_path, target_path);
  return target_path;
};

const prepare_job = async (job_data) => {
  const { job_id } = job_data;
  const input = job_data.input || {};
  const prompt = input.prompt || job_data.prompt;
  const audio_url = input.audio_url || input.reference_audio || job_data.audio_url;

  if (!prompt) {
    throw new Error(`Job [${job_id}] is missing prompt`);
  }

  let local_ref_path = null;
  if (audio_url) {
    await mkdir(INPUT_DIR, { recursive: true });
    const ext = audio_url.includes('.wav') ? 'wav' : 'mp3';
    const filename = `ref_${WORKER_SUFFIX}_${job_id}.${ext}`;
    local_ref_path = join(INPUT_DIR, filename);
    await download_file(audio_url, local_ref_path);
  }

  return {
    job_id,
    prompt,
    voice_id: input.voice_id || null,
    reference_text: input.reference_text || "",
    speed: input.speed !== undefined ? parseFloat(input.speed) : 1.0,
    format: input.format || 'mp3',
    local_ref_path
  };
};

const probe_audio_metadata = async (file_path) => {
  try {
    const { stdout } = await execFileAsync('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration,size,bit_rate',
      '-of', 'json',
      file_path
    ]);
    const info = JSON.parse(stdout);
    const duration = parseFloat(info?.format?.duration) || 0;
    return {
      duration_sec: Number(duration.toFixed(2)),
      size_bytes: parseInt(info?.format?.size, 10) || statSync(file_path).size,
      bit_rate: parseInt(info?.format?.bit_rate, 10) || null
    };
  } catch (err) {
    console.warn(`${TAG} ffprobe fallback warning: ${err.message}`);
    return { duration_sec: 1.0 };
  }
};

const execute_tts = async (job) => {
  const start_time = Date.now();
  await mkdir(OUTPUT_DIR, { recursive: true });

  const output_ext = job.format || 'mp3';
  const raw_output_path = join(OUTPUT_DIR, `synth_${WORKER_SUFFIX}_${job.job_id}.${output_ext}`);

  const references = [];
  if (job.local_ref_path) {
    const refBuffer = await readFile(job.local_ref_path);
    references.push({
      audio: refBuffer.toString('base64'),
      text: job.reference_text || ""
    });
  }

  const payload = {
    text: job.prompt,
    references,
    format: output_ext === 'wav' ? 'wav' : 'mp3',
    streaming: false
  };

  const response = await fetch(`${TTS_HOST}/v1/tts`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(180000)
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Fish Audio backend returned HTTP ${response.status}: ${errText}`);
  }

  const audio_buffer = await response.arrayBuffer();
  if (audio_buffer.byteLength === 0) {
    throw new Error('Received 0 bytes from TTS inference engine');
  }

  await writeFile(raw_output_path, Buffer.from(audio_buffer));
  const generation_time_sec = Number(((Date.now() - start_time) / 1000).toFixed(2));

  const metadata = await probe_audio_metadata(raw_output_path);
  metadata.format = output_ext;

  return {
    output_path: raw_output_path,
    generation_time_sec,
    metadata
  };
};

const upload_to_r2 = async (file_path, job_id, format) => {
  const key = `tts/${job_id}.${format}`;
  const contentType = format === 'wav' ? 'audio/wav' : 'audio/mpeg';
  const file_size = statSync(file_path).size;

  console.log(`${TAG} [R2] Uploading ${file_path} (${(file_size / 1024).toFixed(1)} KB) to ${key}...`);

  await s3_client.send(new PutObjectCommand({
    Bucket: R2_BUCKET_NAME,
    Key: key,
    Body: createReadStream(file_path),
    ContentLength: file_size,
    ContentType: contentType,
  }));

  return `${R2_CDN_URL}/${key}`;
};

const complete_job = async (job_id, output_url, generation_time_sec, metadata) => {
  const res = await fetch(`${API_BASE_URL}/v1/worker/complete`, {
    method: 'POST',
    headers: get_api_headers(),
    body: JSON.stringify({
      session_id: WORKER_SESSION_ID,
      worker_id: UNIQUE_WORKER_ID,
      job_id,
      output_url,
      generation_time_sec,
      metadata
    }),
    signal: AbortSignal.timeout(15000)
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Complete API rejected HTTP ${res.status}: ${errText}`);
  }

  jobs_processed += 1;
  total_generation_time_sec += generation_time_sec;
  await sync_stats_to_disk();
};

const fail_job = async (job_id, error_message) => {
  try {
    await fetch(`${API_BASE_URL}/v1/worker/fail`, {
      method: 'POST',
      headers: get_api_headers(),
      body: JSON.stringify({
        session_id: WORKER_SESSION_ID,
        worker_id: UNIQUE_WORKER_ID,
        job_id,
        error_message: String(error_message)
      }),
      signal: AbortSignal.timeout(15000)
    });
  } catch (err) {
    console.error(`\x1b[31m${TAG} Fail API Network Error [${job_id}]: ${err.message}\x1b[0m`);
  }
};

const upload_and_complete_async = async (job_id, isolated_path, generation_time_sec, metadata, format) => {
  try {
    const r2_url = await upload_to_r2(isolated_path, job_id, format);
    await complete_job(job_id, r2_url, generation_time_sec, metadata);
    console.log(`\x1b[32m${TAG} ✔ Job [${job_id}] completed | ${metadata.duration_sec}s audio | ${generation_time_sec}s compute\x1b[0m`);
  } catch (err) {
    console.error(`\x1b[31m${TAG} ✖ Upload/Settle Failed [${job_id}]: ${err.message}\x1b[0m`);
    await fail_job(job_id, err.message);
  } finally {
    try { await unlink(isolated_path); } catch (_) {}
  }
};

const wait_for_tts_backend_ready = async () => {
  console.log(`${TAG} Waiting for TTS backend on ${TTS_HOST}...`);
  while (true) {
    try {
      const res = await fetch(`${TTS_HOST}/v1/health`, { signal: AbortSignal.timeout(3000) });
      if (res.ok) break;
    } catch (_) {}
    await sleep(1000);
  }
  console.log(`${TAG} TTS backend connected and healthy.`);
};

const prefetch_next_job = async () => {
  try {
    return await poll_for_job();
  } catch (err) {
    console.error(`\x1b[31m${TAG} Prefetch error: ${err.message}\x1b[0m`);
    return null;
  }
};

const cleanup_temp_file = async (file_path) => {
  if (file_path) {
    try { await unlink(file_path); } catch (_) {}
  }
};

const worker_loop = async () => {
  await mkdir(INPUT_DIR, { recursive: true });
  await mkdir(OUTPUT_DIR, { recursive: true });
  await sync_stats_to_disk();
  await wait_for_tts_backend_ready();

  let current_job = null;
  let prefetch_promise = null;
  let empty_poll_count = 0;

  while (true) {
    try {
      if (prefetch_promise) {
        current_job = await prefetch_promise;
        prefetch_promise = null;
      }

      if (!current_job) {
        current_job = await poll_for_job();
      }

      if (!current_job) {
        empty_poll_count++;

        if (empty_poll_count >= MAX_EMPTY_POLLS) {
          console.warn(`\x1b[33m${TAG} Queue empty for ${MAX_EMPTY_POLLS} consecutive polls. Draining...\x1b[0m`);
          if (active_uploads.size > 0) {
            console.log(`${TAG} Awaiting ${active_uploads.size} active background upload(s)...`);
            await Promise.allSettled(Array.from(active_uploads));
          }
          await sync_stats_to_disk();
          process.exit(0);
        }

        await sleep(POLL_INTERVAL_SECONDS * 1000);
        continue;
      }

      empty_poll_count = 0;
      console.log(`${TAG} Claimed Job [${current_job.job_id}]`);

      prefetch_promise = prefetch_next_job();

      try {
        const { output_path, generation_time_sec, metadata } = await execute_tts(current_job);
        await cleanup_temp_file(current_job.local_ref_path);

        const isolated_path = join(OUTPUT_DIR, `uploading_${WORKER_SUFFIX}_${current_job.job_id}.${current_job.format}`);
        await rename(output_path, isolated_path);

        const upload_task = upload_and_complete_async(
          current_job.job_id,
          isolated_path,
          generation_time_sec,
          metadata,
          current_job.format
        );
        active_uploads.add(upload_task);
        upload_task.finally(() => active_uploads.delete(upload_task));

      } catch (synth_err) {
        console.error(`\x1b[31m${TAG} ✖ Synthesis failed [${current_job.job_id}]: ${synth_err.message}\x1b[0m`);
        await cleanup_temp_file(current_job.local_ref_path);
        await fail_job(current_job.job_id, synth_err.message);
      }

      current_job = null;
    } catch (loop_err) {
      console.error(`\x1b[31m${TAG} Loop iteration error: ${loop_err.message}\x1b[0m`);
      await sleep(POLL_INTERVAL_SECONDS * 1000);
    }
  }
};

worker_loop();