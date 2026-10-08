# Backtest FVG-D1 (mode STANDARD) — données Axi MT5, oct. 2025 → oct. 2026

Outil : `bt.py` (réplique de la stratégie, bougies M15 + D1, hypothèse pessimiste intrabar, spread de la bougie).
Les données ne sont pas dans le dépôt : à récupérer avec `get_mt5_candles` (M15 par tranches de 28 jours, D1).
Sans filtre d'annonces ni commissions. Résultats en multiples de R.

## Réglages par défaut (SL max 25 % ATR D1, filtre calme 0,9)
| Paire | Trades | Espérance (R) |
|---|---|---|
| XAUUSD | 98 | +0,40 |
| EURUSD | 33 | -0,06 |
| GBPUSD | 64 | -0,02 |
| USDJPY | 50 | +0,03 |
| NAS100 | 61 | -0,02 |
| XAGUSD | 50 | +0,01 |

## Balayage forex (216 réglages, EURUSD+GBPUSD+USDJPY, recherche oct-mars / vérification avr-oct)
Réglage retenu : RR 4, FVG 0,5 + BOS, paliers, **SL max 15 % de l'ATR D1, sans filtre « calme »**
→ recherche : 134 trades, +0,19 R ; vérification : 52 trades, +0,15 R.

Par paire avec ce réglage : EURUSD +0,15 R (51 trades), GBPUSD +0,33 R (58), USDJPY +0,09 R (77, négatif sur avr-oct),
NAS100 +0,04 R (79, négatif sur avr-oct), XAGUSD -0,19 R (57). Argent et Nasdaq : non retenus.

## Limites
- 12 mois, 50-70 trades par paire : l'erreur-type de l'espérance est d'environ ±0,17 R, donc rien n'est statistiquement prouvé.
- Réglage choisi parmi 216 essais : biais de sélection.
- Période 2025-26 très haussière sur l'or.
