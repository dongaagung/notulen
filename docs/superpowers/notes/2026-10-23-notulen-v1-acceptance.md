# Notulen v1: uji penerimaan dan tindak lanjut

Semua yang ada di sini berasal dari pengerjaan rencana
`docs/superpowers/plans/2026-10-23-notulen-v1.md` di branch `notulen-v1`.
Pengujian otomatis sudah lulus (325 test). Hal-hal di bawah perlu dicek di
Mac sungguhan oleh pemilik, karena butuh izin sistem, audio meeting asli,
perangkat, atau kunci API.

Pasang dulu dengan `make install`. Perintah ini membangun versi release lalu
menyalinnya ke `/Applications/Notulen.app`.

## 1. Uji go/no-go Bahasa Indonesia (spec §15, plan Task 8)

Uji ini **belum dijalankan**, karena pemilik memilih lanjut dulu. Hasilnya
bisa mengubah lapisan transkripsi (`SttProvider`).

1. Rekam minimal 30 menit meeting sungguhan berbahasa Indonesia, dengan
   bahasa id-ID.
2. **Mutu**: baca tiga potongan transkrip acak, masing-masing 2 menit. Bisakah
   notulen yang benar ditulis dari potongan itu?
3. **Rentang waktu**: lihat file
   `~/Library/Application Support/rakyat.notulen/meetings/<id>/transcript.jsonl`.
   Minimal 90% baris dari channel `meeting` harus punya `end > start`.

   ```sh
   jq -s '[.[]|select(.channel=="meeting")] | {lines: length, ranged: (map(select(.end > .start))|length)}' transcript.jsonl
   ```

4. **Beban**: buka Activity Monitor pada menit ke-30. CPU harus jauh di bawah
   100%. Memori diperkirakan sekitar 200 MB ditambah 1,9 MB per menit audio
   meeting.

## 2. Uji manual

**Rekam dan transkrip**
- [ ] Mulai meeting dengan Zoom/Meet, lalu dengan "Semua audio sistem". Izin
  mic, perekaman audio, dan pengenalan suara harus diminta, dan model id-ID
  harus terunduh.
- [ ] Pilih app meeting yang belum dibuka. App harus menolak dengan pesan
  "… tidak sedang berjalan".
- [ ] Lepas lalu pasang lagi AirPods, dan coba juga headphone di colokan Mac.
  Pemberitahuan mic dan speaker harus muncul, dan transkrip tetap berjalan.
- [ ] Mute di Zoom, lalu matikan mic dengan ⇧⌘M. Selama itu tidak boleh ada
  baris "Saya", dan transkrip menampilkan "Mic mati 12:00–15:30".
- [ ] Ganti mode headset Bluetooth (HFP/A2DP). Mic tidak boleh terjebak
  restart berulang.
- [ ] Pakai audio interface multichannel sebagai mic. Mic harus tetap
  merekam.

**Ketahanan**
- [ ] Tidurkan Mac kurang dari 15 menit: rekaman lanjut sendiri, muncul
  banner, dan transkrip menampilkan "Rekaman terputus … (Mac tidur)".
- [ ] Tidurkan Mac lebih dari 15 menit: app bertanya Lanjutkan/Selesaikan
  dulu.
- [ ] Jalankan `pmset -g assertions` saat merekam. "Notulen sedang merekam"
  harus muncul.
- [ ] Tutup app meeting, lalu coba juga sunyi 10 menit. Tawaran "Meeting
  sepertinya sudah selesai" harus muncul.
- [ ] Jalankan `pkill -9 Notulen` saat merekam, lalu buka app lagi. Pilihan
  "Lanjutkan merekam" dan "Selesaikan dan buat notulen" harus berfungsi.
- [ ] Tekan ⌘Q saat merekam (Keluar dan Batal), lalu ⌘Q saat "Memisahkan
  pembicara…".
- [ ] Matikan internet 5 menit. Catatan sementara tertunda, lalu menyusul
  setelah internet kembali.

**Catatan, notulen, dan pembicara**
- [ ] Catatan sementara muncul sekitar menit 2–3, termasuk kalau kunci API
  baru diisi di tengah meeting.
- [ ] Bandingkan layar live dengan mockup: kapsul toolbar, strip, inspector
  (⌥⌘T), ⌘+/⌘−/⌘0, dan pinch.
- [ ] Meeting 10 menit dengan 3 orang atau lebih: notulen muncul dalam
  sekitar 1–2 menit, dan transkrip menampilkan "Pembicara 1/2/3".
- [ ] Klik penanda waktu di notulen: harus melompat ke baris transkripnya.
  Centang action item harus tetap tersimpan.
- [ ] Ganti nama dan gabungkan pembicara. Saran nama dan "Pakai" harus
  berfungsi.
- [ ] Coba "Buat ulang notulen", lalu terjemahkan ke Inggris dan ke Arab
  (teks Arab harus dari kanan ke kiri di PDF).
- [ ] Setelah notulen jadi, pemakaian memori turun kira-kira sebesar buffer
  audio.

**Ekspor**
- [ ] Salin sebagai Markdown, lalu tempel ke Notion. Heading, daftar, dan
  kotak centang harus tampil benar.
- [ ] Ekspor PDF meeting 1 jam atau lebih: minimal 2 halaman A4, teks bisa
  dipilih, dan waktu berformat h:mm:ss. Ulangi dengan terjemahan tampil, dan
  coba simpan menimpa file lama.
- [ ] Kirim ke Notion dengan token asli, lalu kirim lagi. Halaman yang sama
  harus diperbarui, dan sub-halaman yang kamu tambahkan sendiri tetap ada.
- [ ] Dengan kunci API asli, pastikan Anthropic menerima skema JSON yang
  memakai `"type": [..., "null"]` (catatan sementara dan notulen).

## 3. Masalah yang diketahui (ditunda, tidak menghalangi merge)

- **App meeting terbuka tapi belum memutar audio.** Ini bisa terjadi misalnya
  pada browser sebelum masuk call. App lolos pengecekan di sheet, lalu meeting
  tersimpan "Gagal". Perbaikannya: pakai pengecekan proses Core Audio yang
  sama dengan tap di `begin`.
- **Catatan sementara setelah rekaman dilanjutkan.** Baris yang selesai ditulis
  selama permintaan AI terakhir berjalan tidak dikirim ulang ke catatan
  sementara. Notulen akhir tidak terpengaruh.
- **PDF ditulis langsung ke file tujuan.** Kalau pencetakan gagal di tengah
  jalan, file lama bisa rusak. Perbaikannya: cetak ke file sementara, lalu
  pindahkan.
- **Mic yang izinnya ditolak.** Tombol mic tetap bisa ditekan, padahal
  seharusnya nonaktif.
- **Crash saat mic mati.** Periode mic mati tersimpan dengan panjang nol.
  Perbaikannya: perpanjang sampai `recordedUntil` saat rekaman dilanjutkan.
- **Tanda tanya yang tidak tersimpan.** Teks final yang hanya berisi tanda baca
  (misalnya "?") tidak masuk jurnal.
- **Notion.** Halaman di tempat sampah (400) tidak memicu pembuatan halaman
  baru. Pengiriman ulang notulen panjang menghapus blok satu per satu, sehingga
  lambat.
