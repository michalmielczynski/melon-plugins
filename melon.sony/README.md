# melon.sony — słuchawki Sony WF-1000XM5 w pasku Omarchy

Chip w pasku (bateria + ikona) i panel: bateria osobno dla lewej, prawej i etui,
ANC / Ambient z poziomem i „skoncentruj na głosie", korektor 6-pasmowy,
DSEE Extreme, Speak-to-Chat, pauza po zdjęciu, wyłączanie po zdjęciu, wyłączenie
słuchawek oraz sekcja jakości Bluetooth (LDAC 990 kbps vs profil mikrofonowy).

Sterowanie idzie protokołem **MDR v2** Sony po RFCOMM (usługa
`956c7b26-d49a-4ba8-b03f-b17d393cb6e2`). Sesję kontrolną otwiera BlueZ
(`Profile1`), bo tylko on robi SDP i zna aktualny kanał. Słuchawki dają
**jedną** sesję naraz — dlatego trzyma ją `sony-helper.py`, a panel tylko czyta
jego stan (linie JSON na stdout) i wysyła komendy (JSON na stdin).

## Instalacja

```bash
cp -r . ~/.config/omarchy/plugins/melon.sony
omarchy plugin enable melon.sony        # jeśli nie włączy się sam
omarchy bar move melon.sony --section right
omarchy bar move melon.sony --before omarchy.bluetooth
```

Jakość Bluetooth (LDAC 990 kbps, bez automatycznego zjazdu do profilu
mikrofonowego) ustawia plik WirePlumber:

```bash
sudo install -Dm644 wireplumber/51-sony-xm5-quality.conf \
  /etc/wireplumber/wireplumber.conf.d/51-sony-xm5-quality.conf
systemctl --user restart wireplumber
```

albo bez roota, w `~/.config/wireplumber/wireplumber.conf.d/` — plik jest ten sam.

## Obsługa

* klik — panel, prawy klik — cykl ANC → Ambient → Wyłącz,
* w panelu: sekcje HAŁAS, DŹWIĘK, ZASILANIE, JAKOŚĆ DŹWIĘKU,
* z terminala: `./sonyctl anc ambient`, `./sonyctl eq bass`,
  `./sonyctl auto-off removed`, `./sonyctl audio-profile headset` (patrz `sonyctl`),
* `./sonyctl release` oddaje sesję kontrolną aplikacji Sony w telefonie,
  `./sonyctl claim` bierze ją z powrotem (albo przełącznik w panelu).

## Co jest sprawdzone na sprzęcie

Każdy zapis był weryfikowany tak, jak trzeba: zapis, zamknięcie sesji, nowa
sesja i odczyt — sesja, która pisała, czyta własny optymizm, więc tylko
reconnect mówi prawdę (`tests/fresh_read.py`, `tests/verify_all.py`).

| Funkcja | Odczyt | Zapis |
|---|---|---|
| Bateria (L/P/etui, ładowanie) | tak | — |
| ANC / Ambient / Wyłącz, poziom, focus na głos | tak | **tak, działa** |
| Korektor (6 pasm + clear bass) | tak | **tak, działa** |
| Presety korektora | tak | przyjmuje; „manual" wchodzi, fabryczne bywają ignorowane |
| DSEE Extreme | tak | **tak, działa** |
| Speak-to-Chat | tak | **tak, działa** |
| Pauza po zdjęciu | tak | **tak, działa** |
| Wyłączanie (po zdjęciu / po czasie) | tak | wysyłane, nie potwierdzone reconnectem |
| Wyłącz słuchawki | — | wysyłane, nie potwierdzone |
| Jakość (kodek, profil A2DP/HFP) | tak (pactl) | **tak, przełącza** |

## Notatki o protokole

* Ramka: `3E | esc(typ, seq, len:4BE, payload) | esc(suma) | 3C`, escape `3D`,
  suma = `sum(bytes) & 0xFF` po nagłówku i payloadzie.
* `0x0C` = rozkaz, `0x01` = ACK; na każdy odebrany rozkaz odpowiadamy ACK
  z odwróconym bitem sekwencji, wysyłka ma jedną ramkę w locie i retransmisję
  po 500 ms.
* Po otwarciu sesji: `00 00` (protokół) → `06 00` (lista funkcji) → `66 <asm>`
  (stan NC/ASM). Numer wariantu ASM wybieramy z listy funkcji: XM5 zgłasza
  `0x6B` → używamy `0x17`.
* Odpowiedź na zapis nie jest dowodem: urządzenie potrafi potwierdzić
  i zignorować. Prawda wychodzi tylko z nowej sesji.
* Zdarza się, że pojedynczy GET zginie — helper powtarza brakujące odczyty po
  4 s.
* Dopóki trzymamy sesję, aplikacja Sony w telefonie jej nie dostanie; gdy
  telefon ją trzyma, otwarcie kończy się `br-connection-busy`/`refused` i helper
  ponawia próbę (20 s, potem 2 min).

## Czego (jeszcze) nie ma

* multipoint i panel dotykowy (`GENERAL_SETTING`) — endpoint zwraca *nazwane*
  ustawienia, więc trzeba osobno odczytać ich nazwy,
* lista pozostałych połączeń słuchawek (`PAIRED_DEVICE`) — tego, że dzwoni
  telefon, nie widać ani w BlueZ, ani tutaj,
* przełącznik „priorytet jakości / stabilności" — XM5 potwierdza go i nie
  stosuje (sprawdzone reconnectem).

## Pliki

| Plik | Rola |
|---|---|
| `Panel.qml` | chip w pasku + panel (jedyny entry point pluginu) |
| `sony-helper.py` | sesja MDR, stan po JSON, komendy, gniazdo dla `sonyctl` |
| `sonyctl` | klient CLI do sesji kontrolnej |
| `wireplumber/51-sony-xm5-quality.conf` | LDAC 990 kbps, bez autoswitchu na HFP |
| `tests/` | weryfikacja zapisów świeżą sesją, podgląd ramek (`SONY_TRACE=1`) |
