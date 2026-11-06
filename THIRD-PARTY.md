# Componentes de terceiros

O Espelho é software livre sob a GNU GPL v3.0 (arquivo `LICENSE`). A versão para download leva
dentro do app os componentes abaixo, cada um sob a sua licença. O código-fonte de cada um está
nos links.

| Componente | Para quê | Licença | Código-fonte |
|---|---|---|---|
| UxPlay (com patch do Espelho, `scripts/patch-uxplay.py`) | Receptor AirPlay do iPhone e do iPad | GPL-3.0 | https://github.com/FDH2/UxPlay |
| GStreamer, gst-plugins-base/good/bad, gst-libav | Áudio e transporte do vídeo do UxPlay | LGPL-2.1+ | https://gstreamer.freedesktop.org |
| GLib, libintl (gettext), PCRE2, ORC | Bibliotecas do GStreamer | LGPL-2.1+ / BSD | https://gitlab.gnome.org/GNOME/glib · https://www.gnu.org/software/gettext · https://github.com/PCRE2Project/pcre2 · https://gitlab.freedesktop.org/gstreamer/orc |
| FFmpeg e as bibliotecas de codecs com que foi compilado (x264, x265, libvpx, dav1d, SVT-AV1, Opus, LAME, mpg123, libvmaf, xz) | Decodificar o som AAC e ALAC do iPhone | GPL-2.0+ (build com GPL) e licenças próprias | https://ffmpeg.org e as páginas de cada biblioteca |
| OpenSSL, libplist | Criptografia e plists do AirPlay (embutidos no UxPlay) | Apache-2.0 / LGPL-2.1+ | https://openssl.org · https://github.com/libimobiledevice/libplist |
| scrcpy (servidor) | Espelhamento e controle do Android | Apache-2.0 | https://github.com/Genymobile/scrcpy |
| adb (Android SDK Platform-Tools) | Conexão com o Android | Apache-2.0 | https://developer.android.com/tools/releases/platform-tools |
| Sparkle | Atualizações dentro do app | MIT | https://github.com/sparkle-project/Sparkle |

As bibliotecas são as do Homebrew no Mac que compila a versão (`scripts/make-release.sh`
mostra exatamente quais entram). Para pedir uma cópia do código-fonte de qualquer componente
na versão distribuída, abra uma issue no repositório.
