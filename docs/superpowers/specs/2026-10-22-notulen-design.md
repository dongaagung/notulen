# Notulen: desain

Tanggal: 22 Oktober 2026. Status: menunggu persetujuan.

Dokumen ini ditulis dari percakapan desain antara pemilik proyek dan Claude.
Pilihan yang diambil Claude, bukan oleh pemilik, diberi tanda **(keputusan
Claude)**. Selain itu, semua keputusan berasal dari pemilik.

## 1. Apa dan mengapa

Notulen adalah app macOS native untuk pemakaian pribadi. App ini merekam
meeting online (Zoom, Google Meet, Teams, atau meeting di browser) dari awal
sampai akhir, lalu mentranskripsikannya di Mac. Selama meeting berjalan, app
menampilkan catatan sementara tentang apa yang sedang dibahas. Setelah meeting
selesai, app menulis notulen terstruktur: ringkasan, keputusan, action item,
pertanyaan terbuka, dan rincian per topik.

Patokannya adalah Notion AI Meeting Notes. Pemilik menyukai hampir semua
fiturnya.

**Profil meeting pemilik:**
- Meeting online, biasanya diikuti lebih dari 7 orang, durasinya 1–3 jam.
- Kadang pemilik memimpin, kadang hanya mendengarkan.
- Bahasa meeting bisa apa saja, tapi satu meeting selalu memakai satu bahasa.
- Notulen dibaca pemilik sendiri. Belum ada kebutuhan untuk berbagi atau
  berkolaborasi.

**Hal yang membedakan Notulen dari interview-assistant**, proyek lama yang
stack-nya dipakai ulang:
- Kualitas lebih penting dari kecepatan. Notulen akhir ditulis
  `claude-sonnet-5-5`.
- Hasil AI berupa JSON terstruktur, lalu ditampilkan sebagai tampilan native
  dan Markdown.
- App harus tahan meeting panjang: Mac tidur, headset berganti, app crash.

## 2. Tujuan

1. **Merekam dua jalur terpisah.** Audio app meeting direkam lewat Core Audio
   process tap, dan mic pemilik lewat AVAudioEngine. Dari pemisahan ini, label
   "Saya" didapat tanpa usaha tambahan.
2. **Transkripsi di Mac.** Memakai SpeechAnalyzer, dengan satu bahasa per
   meeting yang dipilih saat mulai. Semua bahasa yang didukung macOS bisa
   dipilih.
3. **Catatan sementara selama meeting.** Catatan disusun per topik. Topik yang
   sedang dibahas disorot, dan poin keputusan atau action item diberi label.
   Catatan diperbarui sekitar setiap 2–3 menit dengan model cepat (Haiku).
4. **Pemisahan pembicara di Mac setelah meeting.** Suara dari app meeting
   dipisah menjadi "Pembicara 1, 2, 3…" memakai FluidAudio. Pemilik bisa
   mengganti nama pembicara dan menggabungkan dua pembicara yang ternyata orang
   yang sama.
5. **Notulen akhir oleh Sonnet**, selalu dalam Bahasa Indonesia, apa pun bahasa
   meetingnya. Isinya berurutan: info meeting dan peserta, ringkasan,
   keputusan, action item (dengan kotak centang), pertanyaan terbuka, dan topik
   yang dibahas. Setiap poin punya penanda waktu yang bisa diklik untuk melompat
   ke transkrip.
6. **Terjemahan** notulen ke bahasa lain oleh AI. Hasilnya disimpan, dan
   pemilik bisa berpindah bahasa.
7. **Ekspor**: Salin sebagai Markdown, Ekspor PDF, dan Kirim ke Notion.
8. **Ketahanan**: tetap merekam saat Mac nyaris tidur, pindah otomatis saat
   headset berganti, dan transkrip pulih setelah crash.
9. **Tidak menyambung dua meeting** kalau pemilik lupa menekan Selesai.
   Setelah tidur lama, app bertanya dulu. Kalau meeting tampak sudah usai, app
   menawarkan untuk menyelesaikan rekaman.
10. **Tombol mic.** Pemilik bisa mematikan dan menyalakan perekaman mic sendiri,
    misalnya saat mute di Zoom lalu berbicara dengan orang di ruangan, supaya
    obrolan itu tidak masuk sebagai "Saya".
11. **UI bergaya Apple**, dengan pengatur ukuran teks (⌘+ / ⌘− / ⌘0).

## 3. Bukan tujuan (v1)

- **Nama asli otomatis** atau pengenalan suara orang antar-meeting. Nama selalu
  diberikan pemilik. Embedding suara tidak disimpan.
- **Speech-to-text cloud.** Audio tidak pernah keluar dari Mac.
- **Ganti bahasa di tengah meeting.**
- **Meeting tatap muka dengan satu mic.** App tidak dirancang untuk ini.
- **Fitur berbagi, akun, kolaborasi, dan sinkronisasi cloud.**
- **Mengetik catatan sendiri selama meeting** (fitur Notion). **(keputusan
  Claude)** Fitur ini ditunda supaya v1 fokus. Bisa ditambah nanti.
- **Integrasi kalender dan deteksi otomatis meeting dimulai.** Merekam selalu
  dimulai manual. **(keputusan Claude)**
- **Fitur interview-assistant yang tidak dibawa**: QuestionDetector,
  HintGenerator, early hints di TurnTracker, PauseDetector, PrepMatcher,
  Practice, GlobalHotKey, dan overlay panel.

## 4. Anti-tujuan

App ini gagal, walaupun secara teknis berjalan, kalau:

- **Notulen mengarang.** Keputusan yang tidak pernah diambil, pemilik tugas
  yang ditebak, atau tenggat yang tidak pernah disebut. Kalau sesuatu tidak
  jelas, notulen harus menuliskannya apa adanya, misalnya "pemegang tidak
  disebut".
- **Transkrip meeting 3 jam hilang** karena crash, Mac tidur, atau headset
  dicabut.
- **Audio keluar dari Mac**, atau audio mentah tertulis ke disk.
- **Suara orang lain diam-diam terlabel "Saya"** karena suara meeting keluar
  lewat speaker, tanpa peringatan.
- **App terasa seperti web app.** Tampilannya harus terasa seperti app Apple.

## 5. Batasan teknis

Sebagian besar batasan diwarisi dari CLAUDE.md interview-assistant.

- **Build dengan Command Line Tools + SwiftPM saja, tanpa Xcode.** SwiftPM
  dijalankan dengan `--build-system native`, karena backend bawaannya butuh
  Xcode. Swift 6.2+, target macOS 26+.
- **Tidak ada alat khusus Xcode.** Artinya tidak ada `#Preview`, asset catalog,
  atau makro SwiftData. `@State` adalah makro di SDK macOS 27, jadi pakai
  wrapper `@ViewState`. `@Entry` juga makro, jadi pakai `EnvironmentKey`
  manual.
- **Data disimpan sebagai Codable + JSON** di Application Support, bukan
  SwiftData.
- **Mute app meeting tidak diikuti otomatis.** Membaca status mute
  Zoom/Meet/Teams butuh izin Aksesibilitas dan integrasi per app yang rapuh.
  Sebagai gantinya ada tombol mic manual.
- **Kunci API** (provider AI dan Notion) hanya disimpan di Keychain.
- **Audio mentah tidak pernah ditulis ke disk.** Audio meeting boleh ditahan di
  memori sampai pemisahan pembicara selesai, lalu dibuang.
- **Prompt disimpan di `prompts/*.md`** dengan `{{variabel}}`, dimuat oleh
  `PromptTemplate`.
- **Hanya satu provider AI yang aktif**, dan Anthropic adalah default:
  - `claude-haiku-5-5` untuk catatan sementara.
  - `claude-sonnet-5-5` untuk notulen akhir dan terjemahan.
  - Provider lain memakai "fast model" untuk catatan sementara dan "smart model"
    untuk sisanya.
- **Dependensi FluidAudio**, hasil uji build 22 Okt 2026:
  - Versi dikunci di `exact: "0.17.7"` dengan `traits: []`. Opsi `traits: []`
    membuang library Rust 87 MB yang tidak dipakai.
  - Paket ini terbukti terkompilasi dengan CLT saja: debug dan release, 0 error.
    Uji ini dijalankan di folder sementara yang sudah dihapus.
  - Kalau `swift build` macet di "Downloading binary artifact", tambahkan
    `--disable-keychain`. Ini terjadi di sesi non-interaktif.
  - Paket ini pre-1.0 dan sering berubah, jadi versinya harus tetap dikunci.

## 6. Alur pengguna

1. **Meeting Baru** (⌘N). Muncul sheet berisi judul (opsional), sumber audio
   (semua audio sistem, atau satu app dari daftar app yang sedang berbunyi),
   dan bahasa meeting. Sumber audio dan bahasa default-nya diambil dari
   Pengaturan. Pemilik lalu menekan **Mulai**. Kalau model bahasa belum ada di
   Mac, app mengunduhnya dulu dengan progres, sama seperti `prepare()` di
   interview-assistant.
2. **Selama meeting**: layar live (lihat §11). Catatan sementara terus
   diperbarui, dan transkrip bisa dibuka di panel kanan.
3. **Selesai**. Rekaman berhenti, lalu app menampilkan progres dua tahap:
   "Memisahkan pembicara…" (35–90 detik untuk meeting 3 jam) dan "Menulis
   notulen…". Totalnya sekitar 1–2 menit.
4. **Notulen tampil.** Pemilik bisa:
   - mengganti nama dan menggabungkan pembicara,
   - mencentang action item,
   - membuka transkrip,
   - mengekspor, atau menerjemahkan.
5. Semua meeting tersimpan di sidebar dan bisa dibuka lagi kapan saja.

## 7. Arsitektur

```
 Zoom/Meet ──► ProcessTapCapture ──┬─► SpeechAnalyzer (jalur meeting) ──┐
                                   └─► MeetingAudioBuffer (RAM, 16 kHz) │
 Mic ────────► MicCapture ────────────► SpeechAnalyzer (jalur mic) ─────┤
                                                                        ▼
                                           TranscriptJournal (append + fsync)
                                                       │
                       setiap ~2,5 menit ─► LiveNotesUpdater (fast model) ─► livenotes.json
                                                       │
                                  Selesai ─► SpeakerDiarizer (FluidAudio offline)
                                                       │  label "Pembicara N" per baris
                                                       ▼
                                   MinutesWriter (smart model, JSON) ─► meeting.json
                                                       │
                          MinutesView · Markdown · PDF · Notion · Translator
```

**Dipakai ulang dari interview-assistant** (disalin lalu disesuaikan, bukan
dijadikan dependensi):

| Bagian | Asal | Perubahan |
|---|---|---|
| Process tap, daftar app audio | `App/Audio/ProcessTapCapture.swift`, `AudioProcess.swift`, `CoreAudioObject.swift`, `AudioChunk.swift`, `AudioLevel.swift` | Sudah memasang ulang tap saat output berganti. Cukup ganti nama aggregate device. |
| Mic | `App/Audio/MicCapture.swift` | **Tambah**: tangani `AVAudioEngineConfigurationChange` dan perubahan input default, lalu restart engine dalam ±1 detik. |
| Speech | `App/Speech/SpeechAnalyzerProvider.swift`, `SttProvider.swift` | **Tambah** `audioTimeRange` di hasil (start/end per segmen) untuk dicocokkan dengan pemisahan pembicara. `InterviewVocabulary` diganti dengan kosakata kustom dari Pengaturan. Fallback DictationTranscriber untuk bahasa yang tidak didukung SpeechTranscriber (misalnya id-ID) tetap dipakai. |
| AI | `App/AI/LLMClient.swift`, `ClaudeClient.swift`, `OpenAICompatibleClient.swift`, `AIProvider.swift`, `JSONValue.swift`, `PromptTemplate.swift` | `LLMRequest.Purpose` diganti: `.liveNotes` (cepat), `.minutes` dan `.translation` (pintar). |
| Store | `App/Store/JSONFileStore.swift`, `Keychain.swift`, `AppStore.swift`, `AppSettings.swift` | Model data baru (§8). Folder: `~/Library/Application Support/rakyat.notulen`. |
| Transkrip | `App/Live/Transcript.swift` (bagian `Transcript` dan `EchoFilter`) | `TurnTracker` dan `PauseDetector` dibuang. Speaker menjadi ID (lihat §8). |
| Sesi live | `App/Live/LiveSession.swift` | Autosave 10 detik diganti dengan jurnal per baris. Peringatan "meeting sunyi" dipertahankan. |
| UI | `SessionsView`, `AIProviderSection`, `MarkdownText`, `TextScale`, `ViewState` | `SessionsView` menjadi sidebar meeting. `TextScale` ditambah ⌘0. |
| Build | `Makefile`, `scripts/make-icon.swift`, `Package.swift` | Nama dan bundle ID baru, ditambah FluidAudio dan model diarisasi. |

**Komponen baru:**
- `MeetingAudioBuffer`: menyimpan audio jalur meeting di RAM sebagai 16 kHz
  mono Int16 (sekitar 346 MB untuk 3 jam). Audio disimpan per segmen rekaman
  dengan offset waktu meeting, supaya jeda karena Mac tidur bisa dipetakan.
  Buffer ini mengimplementasikan protokol `AudioSampleSource` dari FluidAudio.
  - Batas: 4 jam **(keputusan Claude)**. Audio setelah batas itu tidak ikut
    dipisah, dan baris dari bagian itu tetap berlabel "Lainnya".
  - Buffer di-nol-kan dan dibebaskan setelah diarisasi selesai, atau saat
    meeting dibatalkan.
- `SpeakerDiarizer`: memanggil `OfflineDiarizerManager` dari FluidAudio
  (pipeline VBx, pyannote community-1).
  - **Jangan pernah** pakai `process(url)` atau `makeDiskBackedSource`. Keduanya
    menulis PCM mentah ke direktori temp.
  - Model (sekitar 21 MB) dibundel di app, dan `ModelHub.offlineMode = true`
    sehingga app tidak pernah mengunduh dari Hugging Face.
  - Setiap baris transkrip jalur meeting dicocokkan ke pembicara berdasarkan
    tumpang-tindih waktu terbesar. Nomor pembicara diurutkan berdasarkan siapa
    yang pertama kali bicara.
- `TranscriptJournal`: menulis setiap baris final ke `transcript.jsonl`
  (append + `fsync`). Pemulihan setelah crash membaca file ini.
- `LiveNotesUpdater`: lihat §9.1.
- `MinutesWriter` dan `Translator`: lihat §9.2 dan §9.3.
- `PowerGuard`:
  - Memasang `IOPMAssertion` (PreventUserIdleSystemSleep) selama merekam.
  - Mendengarkan `NSWorkspace.willSleep` dan `didWake`. Sebelum tidur, capture
    dihentikan dengan rapi. Setelah bangun, capture dan speech dijalankan lagi,
    dan sebuah `Gap` dicatat.
- `OutputRouteMonitor`: kalau output default adalah speaker bawaan Mac selama
  merekam, tampilkan peringatan bahwa suara orang lain bisa masuk ke mic.
  `EchoFilter` tetap aktif.
- `NotionExporter`, `PDFExporter`, `MarkdownExporter`: lihat §10.

## 8. Model data

Struktur folder per meeting adalah **(keputusan Claude)**:

```
meetings/<uuid>/meeting.json      metadata, catatan sementara, notulen, terjemahan
meetings/<uuid>/transcript.jsonl  satu TranscriptLine per baris, append-only
```

**`Meeting`:**
- `id`, `title`, `startedAt`, `endedAt?`.
- `status`: `recording` | `interrupted` | `processing` | `ready` | `failed`.
- `language` (BCP 47) dan `audioSource`.
- `gaps: [Gap]`, dengan alasan `sleep` | `crash` | `deviceLost`.
- `micOff: [Interval]`, yaitu periode saat pemilik mematikan mic.
- `speakers: [SpeakerInfo]`. ID-nya `me`, `others`, `s1`, `s2`, … dan setiap
  pembicara punya `name?`.
- `merges: [from: to]`.
- `liveNotes?`.
- `minutes?`, yaitu notulen Bahasa Indonesia.
- `translations: [bcp47: Minutes]`.
- `actionItemsDone: Set<ID>`.
- `notionPageID?`.

**`TranscriptLine`:**
- `id`.
- `channel`: `mic` | `meeting`.
- `speakerID`. Mic selalu `me`. Jalur meeting `others` selama live, lalu `sN`
  setelah diarisasi.
- `text`.
- `start` dan `end`, dalam detik sejak meeting dimulai.

Hasil diarisasi ditulis ke `meeting.json` sebagai peta `lineID → sN`. File
`transcript.jsonl` tidak ditulis ulang.

**Nama pembicara tidak pernah dibakukan di teks AI.** Semua teks notulen
merujuk pembicara dengan token `[[s3]]`, `[[me]]`, dan sejenisnya, lalu renderer
menggantinya dengan nama terbaru. Dengan begitu, mengganti nama atau
menggabungkan pembicara tidak perlu membuat ulang notulen. Ini **(keputusan
Claude)**.

## 9. AI

Semua permintaan AI memakai structured output. Untuk Anthropic,
`output_config.format` sudah didukung oleh `ClaudeClient`. Untuk provider lain,
`OpenAICompatibleClient` sudah punya urutan fallback schema → json_object →
instruksi. Prompt ditulis di `prompts/` dalam Bahasa Indonesia.

### 9.1 Catatan sementara (fast model)

- **Pemicu**: sekitar setiap 150 detik selama ada baris final baru, atau lebih
  cepat kalau sudah ada banyak baris baru. Detailnya diserahkan ke builder.
- **Masukan**: status catatan sementara terakhir (JSON) ditambah baris-baris
  baru sejak update terakhir, dengan label Saya/Lainnya dan waktu mm:ss.
  Transkrip penuh tidak dikirim, supaya biaya dan waktu tetap kecil walaupun
  meeting berjalan 3 jam.
- **Keluaran**: status lengkap yang baru, yaitu
  `{ current_topic, topics: [{ title, points: [{ text, kind: point|decision|action_item|open_question }] }] }`.
- **Offline**: kalau tidak ada internet, update ditunda. Update pertama setelah
  internet kembali mencakup semua baris yang tertunda.
- **Anthropic**: Haiku, effort `low`, tanpa streaming.

### 9.2 Notulen akhir (smart model)

- **Masukan**: transkrip lengkap setelah diarisasi. Formatnya per baris:
  `[mm:ss] [[sN]]: teks`. Meeting 3 jam kira-kira 40–60 ribu token, jadi muat
  dalam satu permintaan tanpa dipotong-potong.
- **Keluaran (JSON)**, dengan nama field final diserahkan ke builder:
  ```
  {
    "title_suggestion": "...",
    "summary": "3–5 kalimat",
    "decisions": [{ "id", "text", "at" }],
    "action_items": [{ "id", "task", "owner": { "speaker": "s3"|"me"|null, "name": "Andi"|null }, "due": "..."|null, "at" }],
    "open_questions": [{ "id", "question", "context", "at" }],
    "topics": [{ "title", "start", "end", "points": ["..."] }],
    "speaker_name_hints": [{ "speaker": "s3", "name": "Andi", "evidence": "..." }]
  }
  ```
- **Aturan di prompt:**
  - Selalu tulis dalam Bahasa Indonesia.
  - Prompt diberi daftar `gaps` dan `micOff`. Kalau tidak ada baris "Saya" di
    periode itu, artinya memang tidak ada yang direkam, bukan pemilik diam.
    Aturan yang sama berlaku untuk catatan sementara.
  - Jangan mengarang. `owner` dan `due` bernilai `null` kalau tidak disebut.
  - `name` hanya diisi kalau nama itu diucapkan di transkrip.
  - `at` adalah detik di transkrip yang mendukung poin tersebut.
- **`speaker_name_hints`** muncul sebagai saran di sheet Ganti Nama, misalnya
  "Pembicara 3 mungkin Andi (dipanggil 'makasih, Andi' di 00:16)". Ini
  **(keputusan Claude)**.
- **Anthropic**: Sonnet, thinking adaptive, effort `high`, `fallbacks:
  "default"`, streaming untuk menghindari timeout.
- **Judul**: kalau pemilik tidak memberi judul, `title_suggestion` dipakai.
- **Tombol "Buat ulang notulen"** tersedia, misalnya setelah pembicara
  digabung. Ini **(keputusan Claude)**.
  - Sebelum membuat ulang, muncul konfirmasi bahwa centang action item dan
    terjemahan yang ada akan dihapus, karena ID-nya berubah.
  - Halaman Notion yang sudah ada diperbarui saat notulen dikirim lagi.

### 9.3 Terjemahan (smart model)

- **Masukan**: `Minutes` dalam Bahasa Indonesia, dengan skema yang sama, plus
  bahasa tujuan.
- **Keluaran**: `Minutes` dengan teks yang sudah diterjemahkan. ID, token
  `[[sN]]`, dan `at` tidak boleh berubah.
- Hasilnya disimpan di `translations`. Pemilik memilih bahasa yang ditampilkan
  lewat menu, dan Salin, PDF, serta Notion mengikuti bahasa yang sedang tampil.

### 9.4 Perkiraan biaya (Anthropic, meeting 3 jam)

Perkiraan ini memakai harga per 22 Okt 2026. Sonnet 5.5: $2 input dan $10
output per juta token. Haiku 5.5: $0,10 input dan $0,50 output.

| Bagian | Perkiraan biaya |
|---|---|
| Catatan sementara, Haiku | ~$0,10–0,15 |
| Notulen akhir | ~$0,25–0,40 |
| Terjemahan, per bahasa | ~$0,05–0,10 |

## 10. Ekspor

Semua ekspor ada di satu menu Bagikan di toolbar, dan semuanya memakai bahasa
yang sedang tampil.

- **Salin sebagai Markdown**: fungsi murni `Minutes → Markdown`.
  - Heading `##` per bagian.
  - Action item ditulis sebagai `- [ ]` atau `- [x]` sesuai centangan.
  - Waktu ditulis sebagai teks `(00:14)`.
  - Token pembicara diganti dengan nama.
- **Ekspor PDF…**: ukuran A4, multi-halaman, tata letak yang sama dengan
  tampilan app, dan file disimpan lewat panel simpan. Caranya diserahkan ke
  builder: HTML ke `WKWebView.createPDF` atau pagination, atau render native.
- **Kirim ke Notion:**
  - Token integrasi internal Notion disimpan di Keychain. ID halaman induk
    disimpan di Pengaturan.
  - Setiap notulen menjadi halaman anak, dengan pemetaan blok berikut:
    `heading_2`, `paragraph`, `to_do` untuk action item, dan
    `bulleted_list_item`.
  - `notionPageID` disimpan. Kalau dikirim lagi, isi halaman yang sama diganti,
    tidak membuat halaman baru. Ini **(keputusan Claude)**.
  - Versi API Notion dicek builder di dokumentasi terbaru.

## 11. UI

Mockup yang sudah disetujui ada di
`.superpowers/brainstorm/84454-1792679965/content/`:
- `live-layout-apple-v2.html`: layar selama meeting.
- `final-notes.html`: notulen akhir.

Ini mockup HTML, jadi app aslinya memakai komponen SwiftUI bawaan.

**Gaya:**
- Komponen SwiftUI bawaan macOS 26 (Liquid Glass datang dari sistem), font SF
  Pro dengan hierarki yang tegas, dan banyak ruang kosong.
- Latar netral (#F5F5F7 di mode terang). Mode gelap mengikuti sistem.
- Satu warna aksen, yaitu biru sistem. Merah hanya untuk penanda rekaman.
- Teks UI dalam Bahasa Indonesia **(keputusan Claude)**.

**Ukuran teks:**
- Pemakaian ulang `TextScale` dengan rentang 85%–240%, tersimpan di Pengaturan.
- Pengaturnya ada tiga: menu Tampilan (Perbesar ⌘+, Perkecil ⌘−, Ukuran Asli
  ⌘0), tombol A/A di toolbar, dan pinch di trackpad **(keputusan Claude)**.
- Berlaku untuk catatan, transkrip, dan notulen. Sidebar dan toolbar tetap
  memakai ukuran sistem.

**Jendela utama:** `NavigationSplitView`.
- Sidebar berisi meeting yang dikelompokkan per tanggal (Hari ini, Minggu ini,
  per bulan).
- Meeting yang sedang direkam ditandai titik merah.
- Ada kolom cari berdasarkan judul dan isi **(keputusan Claude)**, dan tombol
  "Meeting Baru".

**Layar live:**
- **Toolbar**: judul, kapsul rekaman (gelombang level + timer), **tombol mic**
  (⇧⌘M), A/A, tombol panel transkrip (⌥⌘T), dan **Selesai** dengan warna
  aksen.
  - Saat mic mati, ikon mic dicoret dan strip bawah menampilkan "Mic mati".
  - Audio meeting tetap direkam.
  - Pintasan ⇧⌘M hanya bekerja saat Notulen aktif, tidak global. Ini
    **(keputusan Claude)**.
- **Isi**:
  - Satu kolom dengan lebar baca terbatas.
  - Baris meta berisi sumber audio, bahasa, dan mic aktif.
  - Label "Sedang dibahas", diikuti judul topik besar dan poin-poinnya.
  - Keterangan "Diperbarui x lalu".
  - Kartu topik sebelumnya, yang bisa dibuka.
- **Strip kaca di bawah**: kalimat terakhir. Teks yang masih berubah tampil
  lebih pudar.
- **Inspector kanan**: transkrip dengan label Saya/Lainnya dan waktu. Panel ini
  otomatis bergulir kecuali pemilik sedang menggulir ke atas.
- **Banner kecil** untuk:
  - mic berganti,
  - suara keluar lewat speaker,
  - meeting sunyi,
  - internet putus (catatan sementara tertunda),
  - rekaman dilanjutkan setelah Mac tidur.

**Notulen akhir:**
- **Toolbar**: segmented control Notulen | Transkrip, A/A, menu Bagikan, dan
  pemilih bahasa kalau ada terjemahan.
- **Isi**:
  - Info meeting: tanggal, jam, durasi, sumber, dan bahasa.
  - Judul, yang bisa disunting.
  - Chip peserta. Pembicara tanpa nama tampil putus-putus dan miring, dengan
    tombol "Ganti nama…".
  - Bagian-bagian notulen: Ringkasan, Keputusan, Action item (kotak centang,
    pemilik, tenggat), Pertanyaan terbuka, dan Topik yang dibahas (rentang
    waktu dan poin).
  - Waktu berwarna biru. Kalau diklik, tab Transkrip terbuka dan baris itu
    disorot.
- **Sheet Ganti Nama**: daftar pembicara, masing-masing dengan 2–3 contoh
  kalimat dan saran nama dari AI. Ada aksi untuk mengganti nama dan
  menggabungkan pembicara.

**Pengaturan:**
- Provider AI (`AIProviderSection` dipakai ulang).
- Bahasa default dan sumber audio default.
- Kosakata kustom.
- Ukuran teks.
- Notion: token dan halaman induk.
- Halaman Tentang yang memuat atribusi lisensi model (lihat §13).

## 12. Ketahanan

- **Mac mau tidur**:
  - Selama merekam, `PowerGuard` mencegah Mac tidur sendiri. Layar boleh mati.
  - Kalau Mac tetap tidur (layar ditutup tanpa monitor eksternal, atau baterai
    kritis), capture berhenti dengan rapi dan `Gap(sleep)` dicatat.
  - **Tidur ≤ 15 menit**: saat Mac bangun, capture otomatis dilanjutkan.
  - **Tidur > 15 menit**: saat Mac bangun, app **tidak** langsung merekam.
    Jendela Notulen tampil di depan dengan dialog "Mac tidur selama 1 jam 20
    menit. Lanjutkan merekam 'Weekly Sync' atau Selesaikan?". Selama belum
    dijawab, app tidak merekam apa pun.
  - Transkrip dan notulen menampilkan jeda tersebut.
- **Meeting tampak sudah usai**:
  - Ini berlaku kalau sumber audionya satu app dan app itu ditutup, atau kalau
    audio meeting sunyi 10 menit berturut-turut.
  - App menampilkan tawaran "Meeting sepertinya sudah selesai. Selesaikan
    rekaman?" dengan pilihan **Selesai** dan **Tetap merekam**.
  - Rekaman tidak dihentikan otomatis.
  - Kalau pemilik memilih Tetap merekam, tawaran berikutnya baru muncul setelah
    sunyi 10 menit lagi.
  - Ambang 15 menit dan 10 menit disimpan sebagai konstanta.
- **Headset berganti**:
  - Mic dijalankan ulang di perangkat input baru dalam ±1 detik.
  - Tap meeting dipasang ulang saat output berganti. Kemampuan ini sudah ada
    di `ProcessTapCapture`.
  - Kalau output berpindah ke speaker bawaan, muncul peringatan.
- **Crash, force quit, atau listrik mati**:
  - Setiap baris final langsung masuk jurnal, jadi paling banyak beberapa detik
    terakhir yang hilang.
  - `meeting.json`, termasuk catatan sementara, disimpan setiap kali berubah.
  - Saat app dibuka dan ada meeting berstatus `recording`, statusnya diubah
    menjadi `interrupted` dan muncul dialog **Lanjutkan merekam** atau
    **Selesaikan dan buat notulen**.
  - Audio sebelum crash sudah hilang, jadi baris dari bagian itu tetap berlabel
    "Lainnya". Diarisasi hanya mencakup audio setelah rekaman dilanjutkan.
- **Keluar app saat merekam**: muncul konfirmasi. Kalau pemilik tetap keluar,
  meeting disimpan sebagai `interrupted`.
- **Internet putus**: transkripsi tetap jalan. Catatan sementara ditunda.
  Kalau notulen gagal dibuat, status menjadi `failed`, transkrip tetap utuh,
  dan ada tombol **Coba lagi**.
- **Diarisasi gagal**: notulen tetap dibuat, dengan semua suara dari app
  meeting berlabel "Lainnya".
- **Kunci API belum diisi**: rekaman dan transkrip tetap jalan. Catatan
  sementara dan notulen menampilkan ajakan untuk mengisi kunci di Pengaturan.

## 13. Privasi dan lisensi

- Audio diproses di Mac dan tidak pernah ditulis ke disk. Buffer RAM
  dibebaskan setelah diarisasi.
- Embedding suara hanya dipakai di dalam proses diarisasi dan tidak disimpan,
  karena embedding termasuk data biometrik.
- Yang dikirim ke provider AI hanya teks: transkrip dan notulen. Yang dikirim
  ke Notion hanya notulen.
- Model diarisasi community-1 berlisensi CC-BY-4.0. Atribusi untuk pyannote,
  WeSpeaker, BUT Speech@FIT, dan Fluid Inference wajib dicantumkan di halaman
  Tentang dan README. Kode FluidAudio berlisensi Apache-2.0.
- Info.plist memuat `NSMicrophoneUsageDescription`,
  `NSAudioCaptureUsageDescription`, dan
  `NSSpeechRecognitionUsageDescription`. Entitlement:
  `com.apple.security.device.audio-input`.

## 14. Pengujian

**Unit test** dengan Swift Testing, dijalankan lewat `make test` seperti di
interview-assistant:
- Pemulihan dari jurnal, termasuk baris terakhir yang terpotong.
- Pemetaan baris transkrip ke pembicara berdasarkan tumpang-tindih waktu.
- Penomoran dan penggabungan pembicara.
- Decode JSON `Minutes` dan `LiveNotes`.
- Penggantian token `[[sN]]`.
- `Minutes → Markdown`.
- `Minutes → blok Notion`.
- Render prompt.
- `TextScale`, termasuk ⌘0.
- Pemetaan `Gap` dan `micOff`.
- Aturan setelah bangun: tidur ≤ 15 menit lanjut, > 15 menit bertanya.
- Tawaran "meeting usai": app ditutup, sunyi 10 menit, dan tidak muncul lagi
  setelah ditolak sampai sunyi 10 menit berikutnya.

**Uji manual sebelum dianggap selesai:**
- Meeting nyata 15 menit dengan 3 orang atau lebih.
- Mac ditidurkan di tengah meeting selama kurang dari 15 menit, lalu lebih
  dari 15 menit.
- Mic dimatikan saat mute di Zoom, lalu dinyalakan lagi.
- AirPods dilepas dan dipasang lagi.
- `kill -9` saat merekam, lalu dipulihkan.
- Internet dimatikan 5 menit.
- Terjemahan ke bahasa Inggris.
- Ekspor PDF dan Notion.

## 15. Risiko terbesar: kualitas transkripsi Bahasa Indonesia

- macOS menangani Bahasa Indonesia hanya lewat DictationTranscriber, mesin dikte
  yang lebih lama. SpeechTranscriber belum mendukungnya.
- Di interview-assistant, mesin ini baru terbukti untuk kalimat pendek dari mic
  dekat. Belum teruji untuk meeting 1–3 jam dengan 7 orang atau lebih yang
  audionya sudah dikompres app meeting.
- **Langkah pertama rencana implementasi adalah uji go/no-go** pada meeting
  sungguhan berbahasa Indonesia, minimal 30 menit. Yang diuji:
  - mutu transkrip,
  - apakah DictationTranscriber memberi `audioTimeRange` yang dibutuhkan
    diarisasi,
  - beban CPU untuk dua jalur sekaligus.
- **Kalau hasilnya tidak layak**, pekerjaan berhenti dan builder kembali ke
  pemilik dengan pilihan. Contohnya mesin on-device lain seperti WhisperKit,
  yang butuh unduhan model besar. Protokol `SttProvider` dipertahankan supaya
  mesin kedua bisa ditambah tanpa membongkar. Ini **(keputusan Claude)**.

## 16. Diserahkan ke builder

- Kadens pasti catatan sementara, nama field JSON final, dan teks prompt.
- Cara membuat PDF dan versi API Notion.
- Cara mendapatkan dan membundel model diarisasi. Misalnya: `make models`
  mengunduh revisi yang dikunci ke folder yang diabaikan git, lalu langkah
  bundle menyalinnya ke `Contents/Resources`.
- Parameter diarisasi, misalnya ambang clustering dan `maxSpeakers` (jumlah
  peserta biasanya tidak diketahui).
- Effort pasti untuk setiap jenis permintaan, setelah dicoba pada transkrip
  nyata.
- README diperbarui setelah fitur jadi, dan CLAUDE.md repo ini ditulis setelah
  dokumen ini disetujui.
