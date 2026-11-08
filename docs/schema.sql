-- read-aloud-agent · SQLite schema v0.1
-- 本地单用户版本。所有时间字段为 ISO8601 UTC 字符串。
-- 应用层负责维护 updated_at；如需数据库层自动更新，可另加触发器。

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('version', '0.1');

-- ---------------------------------------------------------------- 项目
CREATE TABLE IF NOT EXISTS projects (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    title      TEXT NOT NULL,
    language   TEXT NOT NULL DEFAULT 'zh-CN',
    status     TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- ---------------------------------------------------------------- 书籍
CREATE TABLE IF NOT EXISTS books (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    format     TEXT NOT NULL CHECK (format IN ('epub', 'txt')),
    title      TEXT,
    author     TEXT,
    file_path  TEXT NOT NULL,
    file_hash  TEXT NOT NULL,
    parsed_at  TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_books_project ON books(project_id);

-- ---------------------------------------------------------------- 章节
CREATE TABLE IF NOT EXISTS chapters (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id    INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    title      TEXT NOT NULL,
    raw_text   TEXT NOT NULL,
    clean_text TEXT,
    status     TEXT NOT NULL DEFAULT 'parsed'
               CHECK (status IN ('parsed', 'text_review', 'text_ok', 'tagged', 'synthesized', 'verified', 'exported')),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE (book_id, idx)
);
CREATE INDEX IF NOT EXISTS idx_chapters_book ON chapters(book_id);

-- ---------------------------------------------------------------- 角色
CREATE TABLE IF NOT EXISTS characters (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id     INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name           TEXT NOT NULL,
    aliases        TEXT NOT NULL DEFAULT '[]',   -- JSON array
    role_type      TEXT NOT NULL DEFAULT 'supporting'
                   CHECK (role_type IN ('narrator', 'protagonist', 'supporting', 'minor')),
    profile_json   TEXT NOT NULL DEFAULT '{}',   -- 性别/年龄感/性格/说话风格/证据
    casting_status TEXT NOT NULL DEFAULT 'unassigned'
                   CHECK (casting_status IN ('unassigned', 'proposed', 'sample_ready', 'approved')),
    casting_method TEXT CHECK (casting_method IN ('preset', 'design', 'clone', 'reuse')),
    created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_characters_project ON characters(project_id);

-- ---------------------------------------------------------------- 音色
CREATE TABLE IF NOT EXISTS voices (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    character_id        INTEGER NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    mode                TEXT NOT NULL CHECK (mode IN ('preset', 'design', 'clone', 'reuse')),
    preset_voice        TEXT,                    -- 预置音色 ID，如 冰糖
    description         TEXT,                    -- 音色描述（voicedesign 的 context）
    sample_path         TEXT,                    -- 设计生成的候选样本
    clone_ref_path      TEXT,                    -- 实际用于克隆的参考音频
    source_character_id INTEGER REFERENCES characters(id) ON DELETE SET NULL,
    params_json         TEXT NOT NULL DEFAULT '{}',
    status              TEXT NOT NULL DEFAULT 'draft'
                        CHECK (status IN ('draft', 'candidate', 'approved', 'retired')),
    consent_confirmed_at TEXT,                   -- 上传克隆时的授权确认时间
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_voices_character ON voices(character_id);

-- ---------------------------------------------------------------- 段落（核心单元）
CREATE TABLE IF NOT EXISTS segments (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    chapter_id    INTEGER NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
    idx           INTEGER NOT NULL,
    kind          TEXT NOT NULL DEFAULT 'other'
                  CHECK (kind IN ('narration', 'dialogue', 'heading', 'other')),
    speaker_id    INTEGER REFERENCES characters(id) ON DELETE SET NULL,
    text_original TEXT NOT NULL,
    text_current  TEXT NOT NULL,
    tags_text     TEXT,                          -- 带音频标签的文本；NULL 表示未生成
    status        TEXT NOT NULL DEFAULT 'raw'
                  CHECK (status IN ('raw', 'text_review', 'text_ok', 'tagged', 'synthesized', 'verified', 'needs_review', 'approved')),
    locked        INTEGER NOT NULL DEFAULT 0 CHECK (locked IN (0, 1)),
    text_version  INTEGER NOT NULL DEFAULT 1,
    tag_version   INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    UNIQUE (chapter_id, idx)
);
CREATE INDEX IF NOT EXISTS idx_segments_chapter ON segments(chapter_id, idx);
CREATE INDEX IF NOT EXISTS idx_segments_status ON segments(status);
CREATE INDEX IF NOT EXISTS idx_segments_speaker ON segments(speaker_id);

-- ---------------------------------------------------------------- 音频版本
CREATE TABLE IF NOT EXISTS audio_versions (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    segment_id   INTEGER NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
    voice_id     INTEGER REFERENCES voices(id) ON DELETE SET NULL,
    text_hash    TEXT NOT NULL,
    tag_hash     TEXT NOT NULL,
    audio_path   TEXT,
    format       TEXT NOT NULL DEFAULT 'wav',
    duration_ms  INTEGER,
    size_bytes   INTEGER,
    status       TEXT NOT NULL DEFAULT 'ready'
                 CHECK (status IN ('ready', 'failed', 'stale')),
    stale_reason TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_audio_segment ON audio_versions(segment_id);

-- ---------------------------------------------------------------- ASR 回检
CREATE TABLE IF NOT EXISTS asr_results (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    audio_version_id      INTEGER NOT NULL REFERENCES audio_versions(id) ON DELETE CASCADE,
    transcript            TEXT NOT NULL,
    normalized_transcript TEXT,
    cer                   REAL,
    verdict               TEXT CHECK (verdict IN ('pass', 'warn', 'fail')),
    error_types_json      TEXT NOT NULL DEFAULT '[]',
    diff_json             TEXT,                  -- 替换/删除/插入的操作序列
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_asr_audio ON asr_results(audio_version_id);

-- ---------------------------------------------------------------- 问题单
CREATE TABLE IF NOT EXISTS issues (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    chapter_id  INTEGER REFERENCES chapters(id) ON DELETE CASCADE,
    segment_id  INTEGER REFERENCES segments(id) ON DELETE CASCADE,
    stage       TEXT NOT NULL
                CHECK (stage IN ('parse', 'proofread', 'structure', 'speaker', 'tagging', 'tts', 'asr')),
    type        TEXT NOT NULL,
    severity    TEXT NOT NULL DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high')),
    original    TEXT,
    suggested   TEXT,
    confidence  REAL,
    status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'rejected')),
    detail_json TEXT NOT NULL DEFAULT '{}',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    resolved_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_issues_project ON issues(project_id, status);
CREATE INDEX IF NOT EXISTS idx_issues_segment ON issues(segment_id);

-- ---------------------------------------------------------------- 任务
CREATE TABLE IF NOT EXISTS jobs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    chapter_id INTEGER REFERENCES chapters(id) ON DELETE CASCADE,
    stage      TEXT NOT NULL
               CHECK (stage IN ('parse', 'proofread', 'extract_characters', 'attribute_speakers',
                                'design_voice', 'tag', 'synthesize', 'asr_check', 'export')),
    status     TEXT NOT NULL DEFAULT 'queued'
               CHECK (status IN ('queued', 'running', 'done', 'failed', 'canceled')),
    progress   REAL NOT NULL DEFAULT 0,
    total      INTEGER NOT NULL DEFAULT 0,
    done       INTEGER NOT NULL DEFAULT 0,
    error      TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    started_at  TEXT,
    finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_project ON jobs(project_id, status);

-- ---------------------------------------------------------------- 事件（时间线 / 审计）
CREATE TABLE IF NOT EXISTS events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id   INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type         TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}',
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_events_project ON events(project_id, id);

-- ---------------------------------------------------------------- 专名词典
CREATE TABLE IF NOT EXISTS glossaries (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    term       TEXT NOT NULL,
    reading    TEXT,
    type       TEXT NOT NULL DEFAULT 'term' CHECK (type IN ('name', 'term', 'polyphone')),
    note       TEXT,
    UNIQUE (project_id, term)
);

-- ---------------------------------------------------------------- LLM 调用记录
CREATE TABLE IF NOT EXISTS llm_calls (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id        INTEGER REFERENCES projects(id) ON DELETE SET NULL,
    task              TEXT NOT NULL,
    provider          TEXT NOT NULL,
    model             TEXT NOT NULL,
    prompt_tokens     INTEGER,
    completion_tokens INTEGER,
    latency_ms        INTEGER,
    ok                INTEGER NOT NULL DEFAULT 1 CHECK (ok IN (0, 1)),
    error             TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_llm_calls_project ON llm_calls(project_id, created_at);

-- ---------------------------------------------------------------- 导出
CREATE TABLE IF NOT EXISTS exports (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id  INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    format      TEXT NOT NULL CHECK (format IN ('mp3', 'm4b', 'srt_bundle')),
    file_path   TEXT,
    status      TEXT NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued', 'running', 'done', 'failed')),
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    finished_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_exports_project ON exports(project_id);

-- ---------------------------------------------------------------- 设置
CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value_json TEXT NOT NULL,
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
