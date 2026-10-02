# melon.rekuperacja

Sterowanie rekuperacją **Thessla Green AirPack Home 500h** z paska Omarchy:
on/off, biegi wentylacji, tryb pracy, sezon, funkcje specjalne, bypass i
— lokalnie, bez chmury i bez aplikacji AirMobile.

Widget nie gada z centralą bezpośrednio. Po LAN-ie odpytuje **mostek HTTP na
Raspberry Pi** (`192.168.0.90:8770`), który wystawia REST API nad Modbus RTU
(`/dev/ttyAMA0`, half-duplex GPIO17). Źródła mostka:
`~/Projects/rekuperator/bridge/bridge.py` (wdrożony jako
`/home/pi/rekuperator/bridge.py` + `/etc/init.d/rekuperator-bridge`).

## Praca hybrydowa (ważne)

> ⚠️ **2026-09-17**: ZenSystem/AirMobile jest świadomie **wyłączony** (chmura `zenremote.pl`
> odrzuca naszego listenera — patrz wiki `rekuperacja-modbus`). Mostek działa teraz z
> `RK_ZEN=0` (`/etc/default/rekuperator-bridge`): nikogo nie zatrzymuje ani nie przywraca,
> a port RS485 należy do niego na stałe — pierwszy odczyt trwa ~2,3 s zamiast ~5 s.
> Model hybrydowy opisany niżej wraca po odkomentowaniu czterech linii `screen -dmS …`
> w `/home/pi/rc.local` i ustawieniu `RK_ZEN=1`. Sterowanie z telefonu w tym trybie:
> apka Android `pl.melon.rekuperacja` (`~/Projects/rekuperator/android/`).

Centrala ma jeden port RS485, a trzyma go `ZenSystemConnect.exe` (mostek do
chmury, z którego korzysta aplikacja AirMobile w telefonie). Mostek na RPi:

1. przy pierwszym żądaniu zatrzymuje **tylko `ZenSystemConnect.exe`** (tak jak
   `mbctrl` — nadzorcy `ZenSystemWatchDog.exe`/`ZenMonitor.exe` i tunel
   `socketcli` zostają nietknięte),
2. obsługuje Modbus bezpośrednio,
3. po `RK_IDLE_RELEASE` (domyślnie 30 s) bezczynności sam przywraca
   `ZenSystemConnect` (a gdyby nie zdążył, zrobi to `ZenMonitor`).

Widget odpytuje centralę tylko przy otwartym panelu (co 5 s). Zamknięcie
panelu wysyła `release`, więc aplikacja w telefonie wraca w kilka sekund.
Zamknięty widget nie generuje ruchu — port zostaje przy Zenie.

## Wymagania

- Mostek uruchomiony na RPi: `/etc/init.d/rekuperator-bridge start`
  (autostart przez `update-rc.d rekuperator-bridge defaults`).
- Python 3 na laptopie (helper korzysta tylko ze standardowej biblioteki).

## Konfiguracja

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `RK_BRIDGE` | `http://192.168.0.90:8770` | adres mostka |
| `RK_TIMEOUT` | `25` | timeout żądania (s) — pierwszy odczyt po bezczynności trwa ~5 s |
| `RK_IDLE_RELEASE` (na RPi) | `30` | po ilu sekundach mostek oddaje port Zenowi |

## Interakcja

- **Lewy klik** — panel sterowania, **prawy klik** — on/off, **środkowy** — odśwież.
- W pasku: ikona wentylatora (obraca się, gdy centrale pracuje, czerwona przy
  alarmie) + aktualny strumień nawiewu w m³/h (albo `OFF`/`—`).

## Panel

- kafelki: nawiew, wywiew (m³/h) i temperatura nawiewu + zewnętrzna,
- PRACA: on/off, tryb automatyczny/manualny, sezon lato/zima,
- WENTYLACJA: suwak 10–100% + biegi 30/60/100% (przełącza w tryb manualny),
- FUNKCJE SPECJALNE: brak, wietrzenie, kominek, pusty dom, otwarte okna (bez „okap” — centrala go nie przyjmuje),
- BYPASS: aktywny/zablokowany, tryb 1/2/3 (status freecooling/freeheating),
- TEMPERATURY: zewnętrzna, nawiew, wywiew, za FPX, kanał, GWC, otoczenie,
- stopka: kto trzyma port RS485 (mostek/Zen) i za ile sekund go odda.

## Diagnostyka

```sh
python3 ~/.config/omarchy/plugins/melon.rekuperacja/rekuperacja.py status
python3 ~/.config/omarchy/plugins/melon.rekuperacja/rekuperacja.py health
ssh root@192.168.0.90 'tail -20 /var/log/rekuperator-bridge.log'
```

## Licencja

MIT
