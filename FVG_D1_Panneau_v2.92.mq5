//+------------------------------------------------------------------+
//| FVG_D1_Panneau.mq5 - tableau de bord FVG-D1 + bouton d'envoi      |
//|                                                                  |
//| Analyse en direct sur les prix Axi (MetaTrader 5) :              |
//|  1. Tendance D1 : EMA20/EMA50 sur bougies D1 terminées.          |
//|  2. Signal M15 : FVG >= 0,5 ATR14 + cassure (BOS) + order block. |
//|  3. Entrée limite au bord éloigné du FVG, valable 50 bougies M15.|
//|  4. SL derrière l'order block (max 15 $), TP 4R.                 |
//|  5. Paliers : +1R -> SL entrée, +2R -> SL +1R, +3R -> SL +2R ;   |
//|     clôture après 12 h ; moitié encaissée à +2R (v2.70).         |
//|  6. Liquidité : signal ignoré si un swing non pris est à < 2R.   |
//|  7. Annonces NFP/CPI/FOMC : pas de nouvel ordre de -30 à +60 min,|
//|     ordres du robot annulés 30 min avant.                        |
//|  8. Un seul ordre/position sur le symbole, 2 trades FVG par jour,|
//|     stop journalier -2 % du solde (bonus exclu).                 |
//|                                                                  |
//| Boutons : ENVOYER (avec confirmation), ANNULER MES ORDRES, AUTO, |
//| JOURNAL (statistiques des trades clos + export Excel).          |
//| Pause de 2 h après 2 pertes de suite (règle de discipline).     |
//| Risque 1,5 % par trade, divisé par 2 si le solde est à 5 % sous  |
//| son plus haut ; perte maximale du mois -7 % (reprise le 1er).    |
//| Suivi du test de 40 trades (arrêt si baisse > 15 %) et mesure du |
//| glissement réel sur chaque sortie SL/TP.                         |
//| Modes : STANDARD (par défaut) = stratégie de la v2.60 :          |
//| FVG 0,5 + BOS, sans H1/H4, sortie 24 h (~10 trades/mois) ;       |
//| PRUDENT = règles v2.70 (H1+H4, moitié à +2R, 12 h, vendredi) ;   |
//| ACTIF = FVG 0,2 sans BOS (~24 trades/mois).                      |
//| MIXTE (v2.90) = signaux du mode ACTIF ; risque plein             |
//| si le signal remplit aussi les règles PRUDENT (FVG 0,5 + BOS +   |
//| H1 + H4), sinon demi-risque (~24 trades/mois, baisse max ~7 %).  |
//| Protection (v2.70) : tendances H1 et H4 dans le même sens que le |
//| D1, pas de signal le vendredi après 14 h UTC.                    |
//| Filtre (v2.60) : pas de signal si l'or est trop calme (ATR14 D1  |
//| < 1,5 % du prix) : 5 ans testés, baisse max 26 % -> 9 %.         |
//| v2.92 : stop journalier strict (lot réduit à la perte restante), |
//| filtre de spread (% du risque R), vendredi 14 h aussi en STANDARD,|
//| baisse du test calculée sur l'équité, dépôts/retraits exclus.    |
//| Garde-fou (v2.50) : tout trade manuel ouvert après le démarrage  |
//| du robot est signalé et, au choix, fermé aussitôt.               |
//| Installation : Fichier > Ouvrir le dossier des données > MQL5 >  |
//| Experts : copier ce fichier, l'ouvrir dans MetaEditor, compiler  |
//| (F7), puis le glisser sur un graphique XAUUSD et activer         |
//| « Algo Trading ».                                                |
//+------------------------------------------------------------------+
#property copyright "Méthode FVG-D1"
#property version   "2.92"
#property description "Analyse FVG-D1 en direct (prix Axi), tableau de bord et bouton d'envoi d'ordre."

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_GUARD
  {
   GUARD_OFF   = 0, // Désactivé
   GUARD_ALERT = 1, // Alerte seulement
   GUARD_CLOSE = 2  // Alerte + fermeture immédiate
  };

enum ENUM_MODE
  {
   MODE_PRUDENT  = 0, // Prudent : ~4 trades/mois, baisse max ~5 %
   MODE_ACTIF    = 1, // Actif : ~24 trades/mois, baisse max ~10 %
   MODE_PERSO    = 2, // Personnalisé : réglages ci-dessous
   MODE_STANDARD = 3, // Standard (v2.60) : ~10 trades/mois, baisse max ~8,5 %
   MODE_MIXTE    = 4  // Mixte : ~24 trades/mois, demi-risque hors signaux prudents, baisse max ~7 %
  };

enum ENUM_GSCOPE
  {
   GSCOPE_SYMBOL = 0, // Seulement le symbole du graphique (or)
   GSCOPE_ALL    = 1  // Tous les symboles du compte
  };

input group "Mode du robot"
input ENUM_MODE InpMode      = MODE_STANDARD; // Mode de trading
input bool      InpMixNeedH4 = false;      // Mixte : exiger aussi la tendance H4 (~15 trades/mois, baisse max ~6 %)
input double    InpMixLowRisk = 0.5;       // Mixte : part du risque pour un signal non « prudent » (0,5 = moitié)
input group "Taille des ordres"
input double InpFixedLot     = 0.0;   // Lot fixe (0 = lot calculé avec le risque %)
input double InpRiskPct      = 1.5;   // Risque par trade si lot fixe = 0 (% du solde, bonus exclu)
input double InpMaxLot       = 0.0;   // Lot maximum (0 = pas de limite)
input double InpDDHalvePct   = 5.0;   // Risque divisé par 2 si le solde est à X % sous son plus haut (0 = non)
input double InpMonthStopUSD = 0.0;   // Perte maximale du mois en dollars (0 = utiliser le %)
input double InpMonthStopPct = 7.0;   // Perte maximale du mois en % du solde du 1er (0 = non)
input group "Envoi et gestion"
input bool   InpConfirm      = true;  // Fenêtre de confirmation avant chaque envoi
input bool   InpAutoStart    = false; // Mode automatique activé au démarrage
input bool   InpManageSL     = true;  // Gérer les paliers SL, la demi-sortie et la durée max
input bool   InpManageClaude = false; // Gérer aussi les ordres placés par Claude (commentaire MCP)
input double InpDailyStopPct = 2.0;   // Stop journalier (% du solde, perte réalisée du jour UTC)
input bool   InpDailyStrict  = true;  // Stop journalier strict : le lot est réduit pour ne pas dépasser la perte restante autorisée
input double InpMaxSpreadPct = 10.0;  // Pas d'ordre si le spread dépasse X % du risque R (0 = filtre désactivé)
input int    InpStdFriday    = 14;    // Mode Standard : pas de signal le vendredi dès X h UTC (-1 = non)
input int    InpMaxPerDay    = 2;     // Trades FVG maximum par jour (robot)
input int    InpMaxHoldHours = 24;    // Mode personnalisé : durée maximale d'un trade (heures)
input int    InpPauseLosses  = 2;     // Pertes de suite avant une pause (0 = pas de pause)
input int    InpPauseHours   = 2;     // Durée de la pause (heures)
input group "Garde-fou trades manuels"
input ENUM_GUARD  InpGuard       = GUARD_CLOSE; // Trade manuel détecté : que faire ?
input ENUM_GSCOPE InpGuardScope  = GSCOPE_ALL;  // Marchés surveillés
input bool        InpGuardOrders = true;        // Supprimer aussi les ordres en attente manuels
input bool        InpGuardClaude = false;       // Inclure les ordres placés par Claude sur ton « confirme »
input group "Méthode"
input double InpMinFVG       = 0.5;   // Mode personnalisé : taille minimale du FVG (x ATR M15)
input bool   InpRequireBOS   = true;  // Mode personnalisé : exiger une cassure de structure (BOS)
input double InpRR           = 4.0;   // TP en multiples du risque (R)
input double InpMaxSL        = 15.0;  // SL maximum (dollars de prix)
input int    InpMaxAgeBars   = 50;    // Validité du signal (bougies M15)
input double InpMinRoomR     = 2.0;   // Liquidité cible minimum en R (0 = filtre désactivé)
input double InpMinVolPct    = 1.5;   // Volatilité jour minimum : ATR14 D1 en % du prix (0 = filtre désactivé)
input group "Protection contre les pertes"
input bool   InpTrendH1      = false; // Mode personnalisé : exiger la tendance H1 (EMA20/50) dans le même sens
input bool   InpTrendH4      = false; // Mode personnalisé : exiger la tendance H4 (EMA20/50) dans le même sens
input double InpPartialR     = 0.0;   // Mode personnalisé : encaisser la moitié à +X R (0 = non)
input int    InpFridayStop   = -1;    // Mode personnalisé : pas de signal le vendredi dès X h UTC (-1 = non)
input group "Test de 40 trades"
input string InpTestStart    = "2026.10.08 07:00"; // Début du test (UTC) : trades plus anciens ignorés (test, stop du jour, pause)
input int    InpTestTrades   = 40;    // Nombre de trades du test
input double InpTestStopDD   = 15.0;  // Arrêt si la baisse depuis le début du test dépasse X % (0 = non)
input double InpSlipWarn     = 0.50;  // Glissement moyen d'alerte (dollars de prix)
input group "Annonces (heures UTC)"
input string InpNews = "2026.10.14 12:30 CPI;2026.10.28 18:00 FOMC;2026.11.06 13:30 NFP;2026.11.10 13:30 CPI;2026.12.04 13:30 NFP;2026.12.09 19:00 FOMC;2026.12.10 13:30 CPI"; // Liste AAAA.MM.JJ HH:MM NOM séparée par ;
input int    InpNewsBefore   = 30;    // Pas de nouvel ordre : minutes avant l'annonce
input int    InpNewsAfter    = 60;    // Pas de nouvel ordre : minutes après l'annonce
input group "Affichage et divers"
input long   InpMagic        = 20261007; // Numéro magique du robot
input bool   InpPush         = true;  // Notifications sur le téléphone (MT5 mobile)
input int    InpX            = 10;    // Position du panneau : X
input int    InpY            = 25;    // Position du panneau : Y
input int    InpFont         = 9;     // Taille du texte

#define C_BG       C'13,17,25'
#define C_HDR      C'19,24,35'
#define C_CARD     C'22,29,42'
#define C_LINE     C'38,47,63'
#define C_BORDER   C'38,47,63'
#define C_TXT      C'233,237,243'
#define C_MUTED    C'139,150,170'
#define C_GREEN    C'34,197,94'
#define C_RED      C'239,68,68'
#define C_AMBER    C'245,158,11'
#define C_GREY     C'52,61,79'
#define C_GOLD     C'214,176,72'
#define C_GREEN_BG C'18,58,36'
#define C_RED_BG   C'72,24,28'
#define C_AMBER_BG C'78,52,10'
#define C_GREEN_D  C'21,94,52'
#define C_RED_D    C'127,29,29'
#define C_AMBER_D  C'120,76,8'

struct Sig
  {
   datetime          t;
   int               s;
   double            entry;
   double            sl;
   double            tp;
   double            be;
   double            dS;
   double            room;
   int               age;
   double            gapr;    // taille du FVG en ATR M15
   bool              bosOk;   // cassure de structure présente
   double            q;       // part du risque (1 = plein, 0,5 = demi-risque en mode MIXTE)
  };

Sig      g_best;
bool     g_has      = false;
bool     g_dataOk   = false;
int      g_trend    = 0;
double   g_e20      = 0;
double   g_e50      = 0;
double   g_d1c      = 0;
double   g_vol      = 0;   // ATR14 D1 en % du prix (bougies D1 terminées)
int      g_hH1a     = INVALID_HANDLE;   // EMA20 H1
int      g_hH1b     = INVALID_HANDLE;   // EMA50 H1
int      g_hH4a     = INVALID_HANDLE;   // EMA20 H4
int      g_hH4b     = INVALID_HANDLE;   // EMA50 H4
int      g_trH1     = 0;   // tendance H1 actuelle (bougie terminée)
int      g_trH4     = 0;   // tendance H4 actuelle
datetime g_trWait   = 0;
double   g_minFVG   = 0.5;    // réglages effectifs selon le mode
bool     g_bos      = true;
bool     g_tH1      = true;
bool     g_tH4      = true;
double   g_partR    = 0.0;
int      g_hold     = 24;
int      g_fri      = -1;
datetime g_partWait = 0;
bool     g_warm     = false;   // démarrage : EMA H1/H4 pas encore calculées
double   g_atr      = 0;
double   g_lo10     = 0;
double   g_hi10     = 0;
string   g_info     = "";
datetime g_lastBar  = 0;
datetime g_notified = 0;
datetime g_lastTry  = 0;
datetime g_modWait  = 0;
bool     g_auto     = false;
long     g_off      = 0;
int      g_panelH   = 420;
int      g_rows     = 0;
string   g_sig      = "";
datetime g_tsLast   = 0;
int      g_tN       = 0;
double   g_tNet     = 0;
double   g_tDD      = 0;
double   g_slipAvg  = 0;
double   g_slipMax  = 0;
int      g_slipN    = 0;
datetime g_newsT[];
string   g_newsN[];
datetime g_guardFrom = 0;   // heure serveur du démarrage : les trades plus anciens ne sont pas touchés
datetime g_gWait     = 0;
int      g_guardN    = 0;   // trades/ordres manuels fermés par le garde-fou
int      g_guardA    = 0;   // trades/ordres manuels signalés (mode alerte)
ulong    g_gSeen[];

// Journal
struct Trd
  {
   long              pid;
   datetime          tin;
   datetime          tout;
   string            sym;
   int               s;
   double            vol;
   double            vout;
   double            pin;
   double            pout;
   double            net;
   string            org;
   string            why;
  };

int      g_view     = 0;   // 0 = analyse, 1 = journal
int      g_period   = 1;   // 0 = jour, 1 = 7 jours, 2 = 30 jours, 3 = tout
int      g_jrows    = 0;
datetime g_jLast    = 0;
string   g_jk[];
string   g_jv[];
color    g_jc[];
string   g_jL[];
string   g_jR[];
color    g_jLc[];

//+------------------------------------------------------------------+
//| Petits outils                                                    |
//+------------------------------------------------------------------+
string N(const string s)
  {
   return "FVGP_" + s;
  }

string GvR(const ulong tk)
  {
   return "FVGP_R_" + IntegerToString((long)tk);
  }

string GvE(const ulong tk)
  {
   return "FVGP_E_" + IntegerToString((long)tk);
  }

string GvG(const ulong pid)
  {
   return "FVGP_G_" + IntegerToString((long)pid);
  }

string GvP(const ulong pid)
  {
   return "FVGP_P_" + IntegerToString((long)pid);
  }

string Px(const double v)
  {
   return DoubleToString(v, _Digits);
  }

string CurSym()
  {
   string c = AccountInfoString(ACCOUNT_CURRENCY);
   if(c == "EUR")
      return "€";
   if(c == "USD")
      return "$";
   return c;
  }

string Mo(const double v)
  {
   return DoubleToString(v, 2) + " " + CurSym();
  }

bool IsReal()
  {
   return (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
  }

string Cut(const string s)
  {
   if(StringLen(s) > 63)
      return StringSubstr(s, 0, 62) + "…";
   return s;
  }

void Notify(const string msg)
  {
   Print(msg);
   Alert(msg);
   if(InpPush)
      SendNotification(msg);
  }

int RowH()
  {
   return (int)MathRound(InpFont * 2.1);
  }

//+------------------------------------------------------------------+
//| Heures : le serveur Axi n'est pas en UTC, on affiche tout en UTC  |
//+------------------------------------------------------------------+
void UpdOffset()
  {
   long d = (long)TimeTradeServer() - (long)TimeGMT();
   g_off = (long)MathRound(d / 900.0) * 900;
  }

datetime ToUTC(const datetime srv)
  {
   return (datetime)((long)srv - g_off);
  }

datetime NowUTC()
  {
   return TimeGMT();
  }

string HM(const datetime utc)
  {
   return TimeToString(utc, TIME_MINUTES);
  }

datetime DayStartSrv()
  {
   long u = (long)TimeGMT();
   return (datetime)(u - u % 86400 + g_off);
  }

datetime TestStartSrv()
  {
   datetime st = StringToTime(InpTestStart);
   if(st <= 0)
      return 0;
   return (datetime)((long)st + g_off);
  }

string Dur(const long sec)
  {
   long m = sec / 60;
   if(m < 0)
      m = 0;
   if(m < 60)
      return IntegerToString(m) + " min";
   long h = m / 60;
   if(h < 48)
      return IntegerToString(h) + " h " + IntegerToString(m % 60) + " min";
   return IntegerToString(h / 24) + " j " + IntegerToString(h % 24) + " h";
  }

//+------------------------------------------------------------------+
//| Annonces économiques                                             |
//+------------------------------------------------------------------+
void ParseNews()
  {
   ArrayResize(g_newsT, 0);
   ArrayResize(g_newsN, 0);
   string parts[];
   ushort sep = StringGetCharacter(";", 0);
   int k = StringSplit(InpNews, sep, parts);
   for(int i = 0; i < k; i++)
     {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(StringLen(p) < 16)
         continue;
      datetime t = StringToTime(StringSubstr(p, 0, 16));
      if(t <= 0)
         continue;
      string nm = (StringLen(p) > 17) ? StringSubstr(p, 17) : "Annonce";
      int j = ArraySize(g_newsT);
      ArrayResize(g_newsT, j + 1);
      ArrayResize(g_newsN, j + 1);
      g_newsT[j] = t;
      g_newsN[j] = nm;
     }
  }

int NewsWindow()
  {
   long now = (long)NowUTC();
   for(int i = 0; i < ArraySize(g_newsT); i++)
     {
      long t = (long)g_newsT[i];
      if(now >= t - InpNewsBefore * 60 && now <= t + InpNewsAfter * 60)
         return i;
     }
   return -1;
  }

int NewsNext()
  {
   long now = (long)NowUTC();
   int best = -1;
   for(int i = 0; i < ArraySize(g_newsT); i++)
     {
      if((long)g_newsT[i] <= now)
         continue;
      if(best < 0 || g_newsT[i] < g_newsT[best])
         best = i;
     }
   return best;
  }

//+------------------------------------------------------------------+
//| Calculs de la méthode (identiques au Scanner et au backtest)      |
//+------------------------------------------------------------------+
double EmaLast(const double &a[], const int n, const int period)
  {
   double k = 2.0 / (period + 1);
   double e = a[0];
   for(int i = 1; i < n; i++)
      e = a[i] * k + e * (1.0 - k);
   return e;
  }

void AtrArr(const MqlRates &r[], const int n, double &out[])
  {
   ArrayResize(out, n);
   double tr[];
   ArrayResize(tr, n);
   double s = 0;
   for(int i = 0; i < n; i++)
     {
      if(i == 0)
         tr[i] = r[i].high - r[i].low;
      else
         tr[i] = MathMax(r[i].high - r[i].low,
                         MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      s += tr[i];
      if(i >= 14)
         s -= tr[i - 14];
      out[i] = s / MathMin(i + 1, 14);
     }
  }

bool FvgAt(const MqlRates &r[], const double &atr[], const int i, const int s, Sig &g)
  {
   if(i < 14)
      return false;
   double a = atr[i];
   if(s > 0)
     {
      if(!(r[i].low > r[i - 2].high && r[i].low - r[i - 2].high >= g_minFVG * a))
         return false;
     }
   else
     {
      if(!(r[i].high < r[i - 2].low && r[i - 2].low - r[i].high >= g_minFVG * a))
         return false;
     }
   double gap = (s > 0) ? r[i].low - r[i - 2].high : r[i - 2].low - r[i].high;
   double mx = -DBL_MAX, mn = DBL_MAX;
   for(int t = i - 12; t <= i - 3; t++)
     {
      mx = MathMax(mx, r[t].high);
      mn = MathMin(mn, r[t].low);
     }
   bool bosOk = (s > 0) ? (r[i - 1].close > mx) : (r[i - 1].close < mn);
   if(g_bos && !bosOk)
      return false;
   int ob = -1;
   for(int t = i - 2; t > i - 8; t--)
     {
      bool opp = (s > 0) ? (r[t].close < r[t].open) : (r[t].close > r[t].open);
      if(opp)
        {
         ob = t;
         break;
        }
     }
   if(ob < 0)
      return false;
   double entry = (s > 0) ? r[i - 2].high : r[i - 2].low;
   double sl    = (s > 0) ? MathMin(r[ob].low, r[i - 2].low) : MathMax(r[ob].high, r[i - 2].high);
   double dS    = MathAbs(entry - sl);
   if(dS < 0.3 * a || dS > 4.0 * a)
      return false;
   g.t     = r[i].time;
   g.s     = s;
   g.entry = entry;
   g.sl    = sl;
   g.dS    = dS;
   g.tp    = entry + s * InpRR * dS;
   g.be    = entry + s * dS;
   g.room  = DBL_MAX;
   g.age   = 0;
   g.gapr  = (a > 0) ? gap / a : 0;
   g.bosOk = bosOk;
   g.q     = 1.0;
   return true;
  }

//+------------------------------------------------------------------+
//| Protection : tendance H1/H4 au moment du signal, vendredi soir   |
//+------------------------------------------------------------------+
// 1 = même sens, -1 = sens contraire, 0 = données pas prêtes
int TrendAt(const ENUM_TIMEFRAMES tf, const datetime t, const int s)
  {
   int ha = (tf == PERIOD_H1) ? g_hH1a : g_hH4a;
   int hb = (tf == PERIOD_H1) ? g_hH1b : g_hH4b;
   if(ha == INVALID_HANDLE || hb == INVALID_HANDLE)
      return 0;
   int sh = (t > 0) ? iBarShift(_Symbol, tf, t, false) : 0;
   if(sh < 0)
      return 0;
   double a[1], b[1];
   if(CopyBuffer(ha, 0, sh + 1, 1, a) != 1 || CopyBuffer(hb, 0, sh + 1, 1, b) != 1)
      return 0;   // sh + 1 = dernière bougie terminée au moment t
   if(a[0] == b[0])
      return -1;
   return ((a[0] > b[0]) == (s > 0)) ? 1 : -1;
  }

bool FridayLate(const datetime tSrv)
  {
   if(g_fri < 0)
      return false;
   MqlDateTime d;
   TimeToStruct(ToUTC((datetime)((long)tSrv + 900)), d);   // clôture de la bougie signal, en UTC
   return (d.day_of_week == 5 && d.hour >= g_fri);
  }

double RoomAt(const MqlRates &r[], const int i, const Sig &g)
  {
   double best = DBL_MAX;
   for(int t = MathMax(2, i - 96); t < i - 2; t++)
     {
      if(g.s < 0)
        {
         double x = r[t].low;
         if(x <= r[t - 2].low && x <= r[t - 1].low && x <= r[t + 1].low && x <= r[t + 2].low && x < g.entry)
           {
            bool ok = true;
            for(int u = t + 1; u <= i; u++)
               if(r[u].low <= x)
                 {
                  ok = false;
                  break;
                 }
            if(ok)
               best = MathMin(best, (g.entry - x) / g.dS);
           }
        }
      else
        {
         double x = r[t].high;
         if(x >= r[t - 2].high && x >= r[t - 1].high && x >= r[t + 1].high && x >= r[t + 2].high && x > g.entry)
           {
            bool ok = true;
            for(int u = t + 1; u <= i; u++)
               if(r[u].high >= x)
                 {
                  ok = false;
                  break;
                 }
            if(ok)
               best = MathMin(best, (x - g.entry) / g.dS);
           }
        }
     }
   return best;
  }

// 0 = en attente, 1 = entrée touchée, 2 = SL touché avant, 3 = expiré
int Status(const MqlRates &r[], const int n, const int i, const Sig &g)
  {
   for(int t = i + 1; t < n; t++)
     {
      if(t - i > InpMaxAgeBars)
         return 3;
      bool slHit = (g.s > 0) ? (r[t].low <= g.sl) : (r[t].high >= g.sl);
      if(slHit)
         return 2;
      bool touch = (g.s > 0) ? (r[t].low <= g.entry) : (r[t].high >= g.entry);
      if(touch)
         return 1;
     }
   if(n - 1 - i >= InpMaxAgeBars)
      return 3;
   return 0;
  }

//+------------------------------------------------------------------+
//| Analyse complète (à chaque nouvelle bougie M15)                   |
//+------------------------------------------------------------------+
void Rebuild()
  {
   g_has    = false;
   g_info   = "";
   g_dataOk = false;
   g_trend  = 0;
   double c[];
   ArraySetAsSeries(c, false);
   int nd = CopyClose(_Symbol, PERIOD_D1, 1, 300, c);   // bougies D1 terminées
   if(nd < 60)
     {
      g_info = "Chargement de l'historique D1…";
      return;
     }
   g_e20 = EmaLast(c, nd, 20);
   g_e50 = EmaLast(c, nd, 50);
   g_d1c = c[nd - 1];
   if(g_e20 > g_e50 && g_d1c > g_e50)
      g_trend = 1;
   else
      if(g_e20 < g_e50 && g_d1c < g_e50)
         g_trend = -1;
   //--- volatilité du jour : ATR14 D1 (moyenne simple des vrais écarts) en % de la dernière clôture
   MqlRates rd[];
   ArraySetAsSeries(rd, false);
   g_vol = 0;
   if(CopyRates(_Symbol, PERIOD_D1, 1, 15, rd) == 15)
     {
      double sTr = 0;
      for(int k = 1; k < 15; k++)
         sTr += MathMax(rd[k].high - rd[k].low, MathMax(MathAbs(rd[k].high - rd[k - 1].close), MathAbs(rd[k].low - rd[k - 1].close)));
      if(rd[14].close > 0)
         g_vol = sTr / 14.0 / rd[14].close * 100.0;
     }
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, PERIOD_M15, 1, InpMaxAgeBars + 130, r);   // bougies M15 terminées
   if(n < InpMaxAgeBars + 20)
     {
      g_info = "Chargement de l'historique M15…";
      return;
     }
   g_dataOk = true;
   double atr[];
   AtrArr(r, n, atr);
   g_atr  = atr[n - 1];
   g_lo10 = DBL_MAX;
   g_hi10 = -DBL_MAX;
   for(int t = n - 10; t < n; t++)
     {
      g_lo10 = MathMin(g_lo10, r[t].low);
      g_hi10 = MathMax(g_hi10, r[t].high);
     }
   g_trH1 = TrendAt(PERIOD_H1, 0, 1);
   g_trH4 = TrendAt(PERIOD_H4, 0, 1);
   if(g_trend == 0)
      return;
   if(InpMinVolPct > 0 && g_vol > 0 && g_vol < InpMinVolPct)
     {
      g_info = "Or trop calme : volatilité " + DoubleToString(g_vol, 2) + " % < " + DoubleToString(InpMinVolPct, 1) + " %";
      return;
     }
   for(int i = MathMax(14, n - 1 - InpMaxAgeBars); i < n; i++)
     {
      Sig g;
      if(!FvgAt(r, atr, i, g_trend, g))
         continue;
      if(Status(r, n, i, g) != 0)
         continue;
      if(g.dS > InpMaxSL)
        {
         g_info = "Signal " + HM(ToUTC(g.t)) + " ignoré : SL " + DoubleToString(g.dS, 2) + " $ > " + DoubleToString(InpMaxSL, 0) + " $";
         continue;
        }
      g.room = RoomAt(r, i, g);
      if(InpMinRoomR > 0 && g.room < InpMinRoomR)
        {
         g_info = "Signal " + HM(ToUTC(g.t)) + " ignoré : liquidité à " + DoubleToString(g.room, 1) + "R";
         continue;
        }
      if(FridayLate(g.t))
        {
         g_info = "Signal " + HM(ToUTC(g.t)) + " ignoré : vendredi après " + IntegerToString(g_fri) + " h UTC";
         continue;
        }
      bool skip = false;
      for(int q = 0; q < 2 && !skip; q++)
        {
         if((q == 0 && !g_tH1) || (q == 1 && !g_tH4))
            continue;
         int k = TrendAt(q == 0 ? PERIOD_H1 : PERIOD_H4, g.t, g.s);
         if(k != 1)
           {
            g_info = "Signal " + HM(ToUTC(g.t)) + " ignoré : " + (k == 0 ? "historique " : "tendance ") + (q == 0 ? "H1" : "H4") +
                     (k == 0 ? " pas encore chargé" : " contraire");
            skip = true;
           }
        }
      if(skip)
         continue;
      if(InpMode == MODE_MIXTE)
        {
         bool full = (g.gapr >= 0.5 && g.bosOk && TrendAt(PERIOD_H1, g.t, g.s) == 1 && TrendAt(PERIOD_H4, g.t, g.s) == 1);
         g.q = full ? 1.0 : MathMax(0.0, MathMin(1.0, InpMixLowRisk));
        }
      g.age  = n - 1 - i;
      g_best = g;
      g_has  = true;
     }
   if(g_has)
      g_info = "";
  }

//+------------------------------------------------------------------+
//| Lot et risque                                                    |
//+------------------------------------------------------------------+
double LossPerLot(const int s, const double entry, const double sl)
  {
   double p = 0;
   if(OrderCalcProfit(s > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, p) && p != 0)
      return MathAbs(p);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0)
      return 0;
   return MathAbs(entry - sl) / ts * tv;
  }

//+------------------------------------------------------------------+
//| Suivi du test (40 trades) et du glissement réel sur les SL/TP     |
//+------------------------------------------------------------------+
double ParseLevel(const string cm)
  {
   int p = StringFind(cm, "[sl ");
   if(p < 0)
      p = StringFind(cm, "[tp ");
   if(p < 0)
      return 0;
   int q = StringFind(cm, "]", p);
   if(q < 0)
      return 0;
   return StringToDouble(StringSubstr(cm, p + 4, q - p - 4));
  }

void UpdateTestStats()
  {
   if(g_tsLast != 0 && TimeLocal() - g_tsLast < 30)
      return;
   g_tsLast = TimeLocal();
   //--- glissement sur tout l'historique du symbole
   g_slipN = 0;
   g_slipMax = 0;
   double ssum = 0;
   if(HistorySelect(0, TimeTradeServer() + 3600))
     {
      int tot = HistoryDealsTotal();
      for(int i = 0; i < tot; i++)
        {
         ulong dl = HistoryDealGetTicket(i);
         if(dl == 0 || HistoryDealGetString(dl, DEAL_SYMBOL) != _Symbol)
            continue;
         long ent = HistoryDealGetInteger(dl, DEAL_ENTRY);
         if(ent != DEAL_ENTRY_OUT && ent != DEAL_ENTRY_OUT_BY)
            continue;
         double lvl = ParseLevel(HistoryDealGetString(dl, DEAL_COMMENT));
         if(lvl <= 0)
            continue;
         double px  = HistoryDealGetDouble(dl, DEAL_PRICE);
         long   typ = HistoryDealGetInteger(dl, DEAL_TYPE);
         double sl  = (typ == DEAL_TYPE_BUY) ? px - lvl : lvl - px;   // positif = défavorable
         if(sl < 0)
            sl = 0;
         ssum += sl;
         g_slipN++;
         g_slipMax = MathMax(g_slipMax, sl);
        }
     }
   g_slipAvg = (g_slipN > 0) ? ssum / g_slipN : 0;
   //--- test : trades du robot et baisse du compte depuis le début
   g_tN = 0;
   g_tNet = 0;
   g_tDD = 0;
   datetime st = StringToTime(InpTestStart);
   if(st <= 0)
      return;
   st = (datetime)((long)st + g_off);
   if(!HistorySelect(st, TimeTradeServer() + 3600))
      return;
   int tot = HistoryDealsTotal();
   double path[];
   double flows = 0;
   ArrayResize(path, 0);
   for(int i = 0; i < tot; i++)
     {
      ulong dl = HistoryDealGetTicket(i);
      if(dl == 0)
         continue;
      long typ = HistoryDealGetInteger(dl, DEAL_TYPE);
      if(typ == DEAL_TYPE_BALANCE)
        {
         flows += HistoryDealGetDouble(dl, DEAL_PROFIT);   // dépôt (+) ou retrait (-) : pas un résultat de trading
         continue;
        }
      if(typ != DEAL_TYPE_BUY && typ != DEAL_TYPE_SELL)
         continue;
      long   ent = HistoryDealGetInteger(dl, DEAL_ENTRY);
      double v   = HistoryDealGetDouble(dl, DEAL_COMMISSION);
      if(ent == DEAL_ENTRY_OUT || ent == DEAL_ENTRY_INOUT || ent == DEAL_ENTRY_OUT_BY)
         v += HistoryDealGetDouble(dl, DEAL_PROFIT) + HistoryDealGetDouble(dl, DEAL_SWAP);
      if(ent == DEAL_ENTRY_IN && HistoryDealGetString(dl, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(dl, DEAL_MAGIC) == InpMagic)
         g_tN++;
      g_tNet += v;
      int k = ArraySize(path);
      ArrayResize(path, k + 1);
      path[k] = g_tNet;
     }
   double b0 = AccountInfoDouble(ACCOUNT_BALANCE) - g_tNet - flows;   // solde au début du test (dépôts/retraits exclus)
   double pk = b0;
   for(int k = 0; k < ArraySize(path); k++)
     {
      double b = b0 + path[k];
      pk = MathMax(pk, b);
      if(pk > 0)
         g_tDD = MathMax(g_tDD, (pk - b) / pk * 100.0);
     }
   //--- équité actuelle (pertes flottantes comprises, bonus exclu) : la baisse en cours compte aussi
   double flt = AccountInfoDouble(ACCOUNT_EQUITY) - AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_CREDIT);
   double eq  = b0 + g_tNet + flt;
   pk = MathMax(pk, eq);
   if(pk > 0)
      g_tDD = MathMax(g_tDD, (pk - eq) / pk * 100.0);
  }

double PeakBalance()
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   string gv  = "FVGP_PEAK_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   double pk  = GlobalVariableCheck(gv) ? GlobalVariableGet(gv) : 0;
   if(bal > pk)
     {
      pk = bal;
      GlobalVariableSet(gv, pk);
     }
   return pk;
  }

bool InDrawdown()
  {
   double pk = PeakBalance();
   return (InpDDHalvePct > 0 && pk > 0 && AccountInfoDouble(ACCOUNT_BALANCE) < pk * (1.0 - InpDDHalvePct / 100.0));
  }

double EffRiskPct()
  {
   return InDrawdown() ? InpRiskPct / 2.0 : InpRiskPct;
  }

double MonthPnl()
  {
   MqlDateTime d;
   TimeToStruct(TimeGMT(), d);
   d.day  = 1;
   d.hour = 0;
   d.min  = 0;
   d.sec  = 0;
   datetime ms = (datetime)((long)StructToTime(d) + g_off);
   if(!HistorySelect(ms, TimeTradeServer() + 3600))
      return 0;
   double sum = 0;
   int tot = HistoryDealsTotal();
   for(int i = 0; i < tot; i++)
     {
      ulong dl = HistoryDealGetTicket(i);
      if(dl == 0)
         continue;
      long typ = HistoryDealGetInteger(dl, DEAL_TYPE);
      if(typ != DEAL_TYPE_BUY && typ != DEAL_TYPE_SELL)
         continue;
      long ent = HistoryDealGetInteger(dl, DEAL_ENTRY);
      sum += HistoryDealGetDouble(dl, DEAL_COMMISSION);
      if(ent == DEAL_ENTRY_OUT || ent == DEAL_ENTRY_INOUT || ent == DEAL_ENTRY_OUT_BY)
         sum += HistoryDealGetDouble(dl, DEAL_PROFIT) + HistoryDealGetDouble(dl, DEAL_SWAP);
     }
   return sum;
  }

double UsdToAccount(const double usd)
  {
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   if(cur == "USD")
      return usd;
   double r = SymbolInfoDouble(cur + "USD", SYMBOL_BID);      // ex. EURUSD
   if(r > 0)
      return usd / r;
   r = SymbolInfoDouble("USD" + cur, SYMBOL_BID);             // ex. USDJPY
   if(r > 0)
      return usd * r;
   return 0;
  }

bool MonthStopHit(double &mp, double &lim)
  {
   mp  = MonthPnl();
   lim = 0;
   if(InpMonthStopUSD > 0)
      lim = UsdToAccount(InpMonthStopUSD);
   if(lim <= 0 && InpMonthStopPct > 0)
      lim = (AccountInfoDouble(ACCOUNT_BALANCE) - mp) * InpMonthStopPct / 100.0;
   return (lim > 0 && mp <= -lim);
  }

double LotsFor(const Sig &g, const double riskCap = 0.0)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = 0.01;
   if(InpFixedLot > 0)
     {
      double l = MathFloor(InpFixedLot / step + 1e-9) * step;
      return NormalizeDouble(MathMin(MathMax(l, vmin), vmax), 2);
     }
   double pl = LossPerLot(g.s, g.entry, g.sl);
   if(pl <= 0)
      return 0;
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * EffRiskPct() / 100.0;   // le crédit (bonus) n'est pas inclus
   if(g.q > 0 && g.q < 1.0)
      risk *= g.q;   // mode MIXTE : demi-risque pour un signal non « prudent »
   if(g.q <= 0)
      return 0;
   bool capped = false;
   if(riskCap > 0 && risk > riskCap)
     {
      risk   = riskCap;   // stop journalier strict : jamais plus que la perte restante autorisée
      capped = true;
     }
   double lots = MathFloor(risk / pl / step + 1e-9) * step;
   if(lots < vmin)
     {
      if(!capped && vmin * pl <= 1.5 * risk)
         lots = vmin;
      else
         return 0;
     }
   if(InpMaxLot > 0)
      lots = MathMin(lots, InpMaxLot);
   return NormalizeDouble(MathMin(lots, vmax), 2);
  }

//+------------------------------------------------------------------+
//| Compte : résultat du jour, ordres et positions sur le symbole     |
//+------------------------------------------------------------------+
double TodayPnl(int &nFvg, int &streak, datetime &lastLoss)
  {
   nFvg     = 0;
   streak   = 0;
   lastLoss = 0;
   double   sum  = 0;
   datetime from = DayStartSrv();
   datetime ts   = TestStartSrv();
   if(ts > from)
      from = ts;   // jour du démarrage : les trades d'avant le début du test ne comptent pas
   if(!HistorySelect(from, TimeTradeServer() + 3600))
      return 0;
   int tot = HistoryDealsTotal();
   for(int i = 0; i < tot; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long typ = HistoryDealGetInteger(d, DEAL_TYPE);
      if(typ != DEAL_TYPE_BUY && typ != DEAL_TYPE_SELL)
         continue;   // dépôts, retraits, bonus : ignorés
      long ent = HistoryDealGetInteger(d, DEAL_ENTRY);
      sum += HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(ent == DEAL_ENTRY_OUT || ent == DEAL_ENTRY_INOUT || ent == DEAL_ENTRY_OUT_BY)
        {
         double v = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP);
         sum += v;
         if(GlobalVariableCheck(GvG((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID))))
            continue;   // fermé par le garde-fou : compte dans le stop journalier, pas dans la série de pertes
         v += HistoryDealGetDouble(d, DEAL_COMMISSION);
         if(v < -1e-9)
           {
            streak++;
            lastLoss = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
           }
         else
            if(v > 1e-9)
               streak = 0;
        }
      if(ent == DEAL_ENTRY_IN && HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(d, DEAL_MAGIC) == InpMagic)
         nFvg++;
     }
   return sum;
  }

string Origin(const long mg, const string cm)
  {
   if(mg == InpMagic)
      return "robot";
   if(StringFind(cm, "MCP") >= 0)
      return "Claude";
   return "manuel";
  }

void AddLine(string &a[], const string s)
  {
   int k = ArraySize(a);
   ArrayResize(a, k + 1);
   a[k] = s;
  }

int Exposure(string &lines[], bool &dup)
  {
   ArrayResize(lines, 0);
   dup = false;
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      c++;
      long   typ = OrderGetInteger(ORDER_TYPE);
      double pr  = OrderGetDouble(ORDER_PRICE_OPEN);
      string ty  = "ORDRE";
      if(typ == ORDER_TYPE_BUY_LIMIT)
         ty = "BUY LIMIT";
      if(typ == ORDER_TYPE_SELL_LIMIT)
         ty = "SELL LIMIT";
      if(typ == ORDER_TYPE_BUY_STOP)
         ty = "BUY STOP";
      if(typ == ORDER_TYPE_SELL_STOP)
         ty = "SELL STOP";
      if(g_has && MathAbs(pr - g_best.entry) < 10 * _Point &&
         ((g_best.s > 0 && typ == ORDER_TYPE_BUY_LIMIT) || (g_best.s < 0 && typ == ORDER_TYPE_SELL_LIMIT)))
         dup = true;
      AddLine(lines, ty + " " + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + " @" + Px(pr) +
              " SL " + Px(OrderGetDouble(ORDER_SL)) + " TP " + Px(OrderGetDouble(ORDER_TP)) +
              " (" + Origin(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_COMMENT)) + ")");
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      c++;
      bool   buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      AddLine(lines, (buy ? "ACHAT " : "VENTE ") + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + " @" +
              Px(PositionGetDouble(POSITION_PRICE_OPEN)) + " SL " + Px(PositionGetDouble(POSITION_SL)) + " " +
              StringFormat("%+.2f ", pnl) + CurSym() + " (" + Origin(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_COMMENT)) + ")");
     }
   return c;
  }

//+------------------------------------------------------------------+
//| Garde-fou : trades et ordres manuels (hors méthode)              |
//+------------------------------------------------------------------+
bool GuardFirst(const ulong tk)
  {
   int k = ArraySize(g_gSeen);
   for(int i = 0; i < k; i++)
      if(g_gSeen[i] == tk)
         return false;
   ArrayResize(g_gSeen, k + 1);
   g_gSeen[k] = tk;
   return true;
  }

bool GuardWatched(const string sym)
  {
   return (InpGuardScope == GSCOPE_ALL || sym == _Symbol);
  }

bool GuardManualOrigin(const long mg, const string cm)
  {
   if(mg != 0)
      return false;   // ce robot ou un autre robot : jamais touché
   if(!InpGuardClaude && StringFind(cm, "MCP") >= 0)
      return false;   // placé par Claude sur ton « confirme »
   return true;
  }

string GuardTxt()
  {
   if(InpGuard == GUARD_OFF)
      return "garde-fou désactivé";
   string s = (InpGuard == GUARD_CLOSE) ? "garde-fou : fermeture auto" : "garde-fou : alerte";
   int n = g_guardN + g_guardA;
   if(n > 0)
      s += " (" + IntegerToString(n) + ")";
   return s;
  }

void GuardManual()
  {
   if(InpGuard == GUARD_OFF || g_guardFrom == 0)
      return;
   if(TimeLocal() < g_gWait)
      return;
   bool algo  = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0);
   bool act   = (InpGuard == GUARD_CLOSE && algo);
   bool tried = false;
   bool fail  = false;
   //--- positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      if(!GuardWatched(sym))
         continue;
      if(!GuardManualOrigin(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_COMMENT)))
         continue;
      if((datetime)PositionGetInteger(POSITION_TIME) < g_guardFrom)
         continue;   // ouverte avant le démarrage du robot : pas touchée
      long pid = PositionGetInteger(POSITION_IDENTIFIER);
      if(!HistoryOrderSelect((ulong)pid))
         continue;   // ordre d'ouverture pas encore dans l'historique : on réessaie à la seconde suivante
      if((datetime)HistoryOrderGetInteger((ulong)pid, ORDER_TIME_SETUP) < g_guardFrom)
         continue;   // ordre manuel posé avant le démarrage, déclenché après : pas touché non plus
      if(!PositionSelectByTicket(tk))
         continue;
      bool   buy =(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      string d   = (buy ? "ACHAT " : "VENTE ") + sym + " " + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + " @" +
                   DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      if(!act)
        {
         if(GuardFirst(tk))
           {
            g_guardA++;
            Notify("FVG-D1 GARDE-FOU : trade manuel détecté (" + d + "). Il ne suit pas la méthode." +
                   (InpGuard == GUARD_CLOSE ? " Active « Algo Trading » pour qu'il soit fermé." : ""));
           }
         continue;
        }
      GlobalVariableSet(GvG((ulong)pid), 1);
      trade.SetTypeFillingBySymbol(sym);
      tried = true;
      if(trade.PositionClose(tk))
        {
         g_guardN++;
         Notify("FVG-D1 GARDE-FOU : trade manuel fermé (" + d + "). Pas de trade hors méthode : le robot s'en occupe.");
        }
      else
        {
         fail = true;
         if(GuardFirst(tk))
            Notify("FVG-D1 GARDE-FOU : impossible de fermer " + d + " (" + trade.ResultRetcodeDescription() + "). Ferme-le toi-même.");
        }
     }
   //--- ordres en attente
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      if(!GuardWatched(sym))
         continue;
      long otyp = OrderGetInteger(ORDER_TYPE);
      if(otyp == ORDER_TYPE_BUY || otyp == ORDER_TYPE_SELL || otyp == ORDER_TYPE_CLOSE_BY || OrderGetInteger(ORDER_POSITION_ID) != 0)
         continue;   // ordre au marché ou de clôture en cours d'exécution : pas un ordre en attente
      if(!GuardManualOrigin(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_COMMENT)))
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) < g_guardFrom)
         continue;
      string d = "ordre " + sym + " " + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2) + " @" +
                 DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), (int)SymbolInfoInteger(sym, SYMBOL_DIGITS));
      if(!act || !InpGuardOrders)
        {
         if(GuardFirst(tk))
           {
            g_guardA++;
            Notify("FVG-D1 GARDE-FOU : " + d + " manuel détecté. Il ne suit pas la méthode.");
           }
         continue;
        }
      tried = true;
      if(trade.OrderDelete(tk))
        {
         g_guardN++;
         Notify("FVG-D1 GARDE-FOU : " + d + " manuel supprimé. Pas de trade hors méthode.");
        }
      else
        {
         fail = true;
         if(GuardFirst(tk))
            Notify("FVG-D1 GARDE-FOU : impossible de supprimer " + d + " (" + trade.ResultRetcodeDescription() + ").");
        }
     }
   if(tried)
     {
      trade.SetTypeFillingBySymbol(_Symbol);
      g_gWait = TimeLocal() + (fail ? 10 : 2);
     }
  }

//+------------------------------------------------------------------+
//| Peut-on envoyer l'ordre du signal ? (toutes les règles)          |
//+------------------------------------------------------------------+
bool CanSend(string &why, double &lots)
  {
   lots = 0;
   if(!g_has)
     {
      why = "Pas de signal à placer.";
      return false;
     }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      why = "Active « Algo Trading » dans MT5.";
      return false;
     }
   int nw = NewsWindow();
   if(nw >= 0)
     {
      why = "Annonce " + g_newsN[nw] + " à " + HM(g_newsT[nw]) + " UTC : pas de nouvel ordre.";
      return false;
     }
   if(FridayLate((datetime)((long)TimeTradeServer() - 900)))
     {
      why = "Vendredi après " + IntegerToString(g_fri) + " h UTC : pas de nouvel ordre.";
      return false;
     }
   int      nF       = 0;
   int      streak   = 0;
   datetime lastLoss = 0;
   double   pnl      = TodayPnl(nF, streak, lastLoss);
   double   stopAmt  = AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyStopPct / 100.0;
   if(InpDailyStopPct > 0 && pnl <= -stopAmt)
     {
      why = "Stop journalier atteint (" + Mo(pnl) + ").";
      return false;
     }
   double mp = 0, mlim = 0;
   if(MonthStopHit(mp, mlim))
     {
      why = "Perte max du mois atteinte (" + Mo(mp) + ") : reprise le 1er.";
      return false;
     }
   UpdateTestStats();
   if(InpTestStopDD > 0 && g_tDD >= InpTestStopDD)
     {
      why = "Baisse de " + DoubleToString(g_tDD, 1) + " % depuis le début du test : on arrête.";
      return false;
     }
   if(PauseActive(streak, lastLoss))
     {
      why = IntegerToString(streak) + " pertes de suite : pause jusqu'à " + HM(ToUTC(PauseEnd(lastLoss))) + " UTC.";
      return false;
     }
   if(nF >= InpMaxPerDay)
     {
      why = IntegerToString(nF) + " trades FVG déjà pris aujourd'hui.";
      return false;
     }
   string ls[];
   bool   dup = false;
   int    ex  = Exposure(ls, dup);
   if(dup)
     {
      why = "Ordre déjà en place pour ce signal.";
      return false;
     }
   if(ex > 0)
     {
      why = "Déjà un ordre ou une position sur " + _Symbol + ".";
      return false;
     }
   double h0 = iHigh(_Symbol, PERIOD_M15, 0);
   double l0 = iLow(_Symbol, PERIOD_M15, 0);
   if((g_best.s < 0 && h0 >= g_best.entry) || (g_best.s > 0 && l0 > 0 && l0 <= g_best.entry))
     {
      why = "Le prix a déjà touché l'entrée : signal consommé.";
      return false;
     }
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((g_best.s < 0 && g_best.entry <= bid + lvl) || (g_best.s > 0 && g_best.entry >= ask - lvl))
     {
      why = "Le prix est trop près de l'entrée.";
      return false;
     }
   //--- spread : trop large par rapport au risque R, l'entrée/SL n'a plus de sens
   if(InpMaxSpreadPct > 0 && g_best.dS > 0)
     {
      double spr = ask - bid;
      if(spr > g_best.dS * InpMaxSpreadPct / 100.0)
        {
         why = "Spread trop large : " + DoubleToString(spr, 2) + " $ > " + DoubleToString(InpMaxSpreadPct, 0) + " % du risque (" +
               DoubleToString(g_best.dS, 2) + " $).";
         return false;
        }
     }
   double cap = 0;
   if(InpDailyStrict && InpDailyStopPct > 0 && InpFixedLot <= 0)
      cap = MathMax(stopAmt + MathMin(pnl, 0.0), 0.0);   // perte restante autorisée aujourd'hui
   lots = LotsFor(g_best, cap);
   if(lots <= 0)
     {
      why = (cap > 0 || (InpDailyStrict && InpDailyStopPct > 0 && pnl < 0)) ? "Lot minimum trop risqué pour la perte restante autorisée aujourd'hui."
                                                                           : "Lot minimum trop risqué pour le capital.";
      return false;
     }
   why = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Envoi de l'ordre limite à Axi                                     |
//+------------------------------------------------------------------+
bool SendOrder(const bool manual)
  {
   string why;
   double lots;
   if(!CanSend(why, lots))
     {
      if(manual)
         MessageBox(why, "FVG-D1", MB_OK | MB_ICONINFORMATION);
      return false;
     }
   Sig      g     = g_best;
   double   entry = NormalizeDouble(g.entry, _Digits);
   double   sl    = NormalizeDouble(g.sl, _Digits);
   double   tp    = NormalizeDouble(g.tp, _Digits);
   double   risk  = lots * LossPerLot(g.s, entry, sl);
   double   gain  = lots * LossPerLot(g.s, entry, tp);
   datetime expT   = g.t + InpMaxAgeBars * 15 * 60;
   string   side  = (g.s > 0) ? "BUY LIMIT" : "SELL LIMIT";
   if(manual && InpConfirm)
     {
      string msg = "Compte " + (IsReal() ? "RÉEL" : "DÉMO") + " n° " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\n\n" +
                   side + " " + DoubleToString(lots, 2) + " lot " + _Symbol + "\n" +
                   "Entrée : " + Px(entry) + "\n" +
                   "SL : " + Px(sl) + "\n" +
                   "TP : " + Px(tp) + " (" + DoubleToString(InpRR, 0) + "R)\n" +
                   "Expiration : " + HM(ToUTC(expT)) + " UTC\n\n" +
                   "Risque ≈ " + Mo(risk) + "   ·   gain au TP ≈ " + Mo(gain) + "\n\n" +
                   "Envoyer l'ordre à Axi ?";
      if(MessageBox(msg, "Confirmer l'ordre FVG-D1", MB_YESNO | MB_ICONQUESTION) != IDYES)
         return false;
     }
   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   long em = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((em & SYMBOL_EXPIRATION_SPECIFIED) != 0)
      tt = ORDER_TIME_SPECIFIED;
   datetime e2  = 0;
   if(tt == ORDER_TIME_SPECIFIED)
      e2 = expT;
   string   cmt = "FVG-D1 " + HM(ToUTC(g.t));
   trade.SetExpertMagicNumber(InpMagic);
   bool ok = (g.s > 0) ? trade.BuyLimit(lots, entry, _Symbol, sl, tp, tt, e2, cmt)
                       : trade.SellLimit(lots, entry, _Symbol, sl, tp, tt, e2, cmt);
   uint rc = trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      ulong tk = trade.ResultOrder();
      GlobalVariableSet(GvR(tk), g.dS);
      GlobalVariableSet(GvE(tk), (double)expT);
      Notify("FVG-D1 : " + side + " " + DoubleToString(lots, 2) + " " + _Symbol + " @" + Px(entry) + " SL " + Px(sl) + " TP " + Px(tp) +
             " envoyé (n° " + IntegerToString((long)tk) + ", risque " + Mo(risk) + ", expire " + HM(ToUTC(expT)) + " UTC).");
      return true;
     }
   Notify("FVG-D1 : échec de l'envoi, code " + IntegerToString(rc) + " (" + trade.ResultRetcodeDescription() + ").");
   return false;
  }

int CancelMine(const string why)
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(trade.OrderDelete(tk))
         c++;
     }
   if(c > 0)
      Notify("FVG-D1 : " + IntegerToString(c) + " ordre(s) du robot annulé(s) : " + why + ".");
   return c;
  }

//+------------------------------------------------------------------+
//| Gestion : annonces, expiration, paliers SL, 24 h                  |
//+------------------------------------------------------------------+
void ManagePending()
  {
   if(NewsWindow() >= 0)
      CancelMine("annonce économique proche");
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong tk = OrderGetTicket(i);
      if(tk == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetInteger(ORDER_TYPE_TIME) != ORDER_TIME_GTC)
         continue;   // l'expiration est gérée par le serveur
      string gv = GvE(tk);
      if(GlobalVariableCheck(gv) && TimeTradeServer() >= (datetime)GlobalVariableGet(gv))
         if(trade.OrderDelete(tk))
            Notify("FVG-D1 : ordre " + IntegerToString((long)tk) + " expiré, annulé.");
     }
  }

void ManagePositions()
  {
   if(!InpManageSL)
      return;
   if(TimeLocal() < g_modWait)
      return;
   double   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   datetime now = TimeTradeServer();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long   mg     = PositionGetInteger(POSITION_MAGIC);
      string cm     = PositionGetString(POSITION_COMMENT);
      bool   mine   = (mg == InpMagic);
      bool   claude = (InpManageClaude && mg == 0 && StringFind(cm, "MCP") >= 0);
      if(!mine && !claude)
         continue;   // jamais les positions manuelles
      int      s    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double   open = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl   = PositionGetDouble(POSITION_SL);
      double   tp   = PositionGetDouble(POSITION_TP);
      datetime t0   = (datetime)PositionGetInteger(POSITION_TIME);
      long     pid  = PositionGetInteger(POSITION_IDENTIFIER);
      double   R    = 0;
      if(GlobalVariableCheck(GvR((ulong)pid)))
         R = GlobalVariableGet(GvR((ulong)pid));
      if(R <= 0 && tp > 0 && InpRR > 0)
         R = MathAbs(tp - open) / InpRR;
      if(R <= 0)
         continue;
      // sortie après la durée maximale
      if(g_hold > 0 && (long)now - (long)t0 >= (long)g_hold * 3600)
        {
         if(trade.PositionClose(tk))
            Notify("FVG-D1 : position " + IntegerToString(pid) + " clôturée après " + IntegerToString(g_hold) + " h.");
         else
            g_modWait = TimeLocal() + 30;
         continue;
        }
      // meilleur prix atteint depuis l'entrée
      double   best = bid;
      datetime from = (datetime)((long)t0 - (long)t0 % 60 + 60);
      if(from < now)
        {
         double a[];
         if(s > 0)
           {
            int k = CopyHigh(_Symbol, PERIOD_M1, from, now, a);
            for(int j = 0; j < k; j++)
               best = MathMax(best, a[j]);
           }
         else
           {
            int k = CopyLow(_Symbol, PERIOD_M1, from, now, a);
            for(int j = 0; j < k; j++)
               best = MathMin(best, a[j]);
           }
        }
      double fav = (s > 0) ? (best - open) / R : (open - best) / R;
      //--- demi-sortie à +InpPartialR (une seule fois, au prix actuel)
      double favNow = (s > 0) ? (bid - open) / R : (open - ask) / R;
      if(g_partR > 0 && favNow >= g_partR && !GlobalVariableCheck(GvP((ulong)pid)) && TimeLocal() >= g_partWait)
        {
         double vol  = PositionGetDouble(POSITION_VOLUME);
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double half = (step > 0) ? MathFloor(vol / 2.0 / step + 1e-9) * step : 0;
         if(half < vmin - 1e-9 || vol - half < vmin - 1e-9)
            GlobalVariableSet(GvP((ulong)pid), 1);   // 0,01 lot : impossible de couper en deux
         else
           {
            bool okP = trade.PositionClosePartial(tk, NormalizeDouble(half, 2));
            uint rc  = trade.ResultRetcode();
            if(okP && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
              {
               GlobalVariableSet(GvP((ulong)pid), 1);
               Notify("FVG-D1 : +" + DoubleToString(g_partR, 1) + "R atteint, moitié encaissée (" + DoubleToString(half, 2) + " lot à " +
                      Px(s > 0 ? bid : ask) + ").");
              }
            else
              {
               Print("FVG-D1 : demi-sortie refusée, code ", rc, " ", trade.ResultRetcodeDescription());
               if(rc == TRADE_RETCODE_INVALID_VOLUME || rc == TRADE_RETCODE_INVALID_FILL || rc == TRADE_RETCODE_INVALID)
                  GlobalVariableSet(GvP((ulong)pid), 1);   // refus définitif : on garde la position entière
               g_partWait = TimeLocal() + 30;              // sinon nouvel essai dans 30 s ; les paliers SL continuent
              }
           }
         if(!PositionSelectByTicket(tk))
            continue;
         sl = PositionGetDouble(POSITION_SL);
         tp = PositionGetDouble(POSITION_TP);
        }
      int    lvl = (int)MathFloor(fav + 1e-9);
      if(lvl < 1)
         continue;
      double nsl    = NormalizeDouble(open + s * (lvl - 1) * R, _Digits);
      bool   better = (s > 0) ? (sl == 0 || nsl > sl + _Point / 2) : (sl == 0 || nsl < sl - _Point / 2);
      if(!better)
         continue;
      bool passed = (s > 0) ? (bid <= nsl) : (ask >= nsl);
      if(passed)
        {
         // le prix est déjà revenu au palier : sortie comme prévu par la règle
         if(trade.PositionClose(tk))
            Notify("FVG-D1 : palier +" + IntegerToString(lvl) + "R atteint puis prix revenu à " + Px(nsl) + " : position clôturée.");
         else
            g_modWait = TimeLocal() + 30;
         continue;
        }
      if(trade.PositionModify(tk, nsl, tp))
         Notify("FVG-D1 : palier +" + IntegerToString(lvl) + "R atteint, SL déplacé à " + Px(nsl) + " (position " + IntegerToString(pid) + ").");
      else
        {
         Print("FVG-D1 : SL non déplacé, code ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
         g_modWait = TimeLocal() + 30;
        }
     }
  }

//+------------------------------------------------------------------+
//| Panneau                                                          |
//+------------------------------------------------------------------+
void Rect(const string name, const int x, const int y, const int w, const int h)
  {
   string nm = N(name);
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
      ObjectSetInteger(0, nm, OBJPROP_ZORDER, 0);
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, C_BG);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, C_BORDER);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
  }

void Lbl(const string name, const int x, const int y, const string text, const color clr, const int fs = 0, const string font = "Segoe UI", const ENUM_ANCHOR_POINT anc = ANCHOR_LEFT_UPPER)
  {
   string nm = N(name);
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
      ObjectSetInteger(0, nm, OBJPROP_ZORDER, 5);
     }
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, anc);
   ObjectSetString(0, nm, OBJPROP_FONT, font);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, fs > 0 ? fs : InpFont);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetString(0, nm, OBJPROP_TEXT, Cut(text == "" ? " " : text));
  }

void Btn(const string name, const int x, const int y, const int w, const int h, const string text, const color bg, const color fg)
  {
   string nm = N(name);
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
      ObjectSetInteger(0, nm, OBJPROP_ZORDER, 10);
      ObjectSetString(0, nm, OBJPROP_FONT, "Segoe UI Semibold");
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, InpFont);
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, nm, OBJPROP_BORDER_COLOR, bg);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, fg);
   ObjectSetString(0, nm, OBJPROP_TEXT, text);
   ObjectSetInteger(0, nm, OBJPROP_STATE, false);
  }

void Row(int &i, int &y, const string k, const string v, const color vc)
  {
   Lbl("k" + IntegerToString(i), InpX + 12, y, k, C_MUTED);
   Lbl("v" + IntegerToString(i), InpX + 122, y, v, vc);
   i++;
   y += RowH();
  }

//--- éléments graphiques du panneau
void Box(const string name, const int x, const int y, const int w, const int h, const color bg, const color border)
  {
   string nm = N(name);
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nm, OBJPROP_BACK, false);
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nm, OBJPROP_XSIZE, MathMax(1, w));
   ObjectSetInteger(0, nm, OBJPROP_YSIZE, MathMax(1, h));
   ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, border);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
  }

int TextW(const string t, const int fs, const string font)
  {
   uint w = 0, h = 0;
   TextSetFont(font, -fs * 10);
   TextGetSize(t, w, h);
   return (int)w;
  }

int PillR(const string name, const int xRight, const int y, const string text, const color bg, const color fg)
  {
   int fs = InpFont - 1;
   int w  = TextW(text, fs, "Segoe UI Semibold") + 20;
   Box(name + "_b", xRight - w, y, w, fs * 2 + 10, bg, bg);
   Lbl(name + "_t", xRight - w + 10, y + 5, text, fg, fs, "Segoe UI Semibold");
   return w;
  }

void Bar(const string name, const int x, const int y, const int w, const double frac)
  {
   double f  = MathMax(0.0, MathMin(1.0, frac));
   color  fc = (f < 0.5) ? C_GREEN : (f < 0.85) ? C_AMBER : C_RED;
   int    fw = (int)MathRound(f * w);
   Box(name + "_tr", x, y, w, 6, C_LINE, C_LINE);
   Box(name + "_fi", x, y, MathMax(1, fw), 6, fw > 0 ? fc : C_LINE, fw > 0 ? fc : C_LINE);
  }

void Draw()
  {
   if(g_view == 1)
     {
      DrawJournal();
      return;
     }
   //--- données
   bool     real  = IsReal();
   double   bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long     spr   = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   bool     quiet = ((long)TimeTradeServer() - SymbolInfoInteger(_Symbol, SYMBOL_TIME) > 300);
   int      nF = 0, streak = 0;
   datetime lastLoss = 0;
   double   pnl     = TodayPnl(nF, streak, lastLoss);
   double   bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double   stopAmt = bal * InpDailyStopPct / 100.0;
   bool     stopHit = (InpDailyStopPct > 0 && pnl <= -stopAmt);
   bool     pause   = PauseActive(streak, lastLoss);
   double   mp = 0, mlim = 0;
   bool     mHit = MonthStopHit(mp, mlim);
   string   ls[];
   bool     dup = false;
   int      ex  = Exposure(ls, dup);
   string   why;
   double   lots2;
   bool     ok  = CanSend(why, lots2);
   int      nl  = MathMin(ArraySize(ls), 4);
   bool     watch = (!g_has && g_trend != 0 && g_dataOk);
   bool     info  = (!g_has && g_info != "");
   string   sig = (g_has ? "S" : "N") + (watch ? "W" : "") + (info ? "I" : "") + IntegerToString(nl);
   if(sig != g_sig)
     {
      ObjectsDeleteAll(0, "FVGP_");   // la mise en page change : on redessine dans l'ordre
      g_sig = sig;
      g_rows = 0;
      g_jrows = 0;
     }
   //--- mise en page
   int x0 = InpX, y0 = InpY, W = 540, P = 18, fs = InpFont;
   int hSig  = g_has ? 132 : 60 + (watch ? 40 : 0) + (info ? 20 : 0);
   int hRisk = 208;
   int hPos  = 40 + 18 * MathMax(1, nl);
   int yMk   = y0 + 62;
   int ySig  = yMk + 116;
   int yRisk = ySig + hSig + 10;
   int yPos  = yRisk + hRisk + 10;
   int yStat = yPos + hPos + 10;
   int yBtn  = yStat + 42;
   int yFoot = yBtn + 44;
   int H     = yFoot + 24 - y0;
   //--- fonds (dans l'ordre : fond, en-tête, cartes, jauges)
   Box("bg", x0, y0, W, H, C_BG, C_LINE);
   Box("hdr", x0, y0, W, 52, C_HDR, C_HDR);
   Box("acc", x0, y0, 4, 52, C_GOLD, C_GOLD);
   Box("cSig", x0 + 10, ySig, W - 20, hSig, C_CARD, C_LINE);
   Box("cRisk", x0 + 10, yRisk, W - 20, hRisk, C_CARD, C_LINE);
   Box("cPos", x0 + 10, yPos, W - 20, hPos, C_CARD, C_LINE);
   color stc = ok ? C_GREEN_D : (stopHit || mHit) ? C_RED_D : C_AMBER_D;
   Box("stat", x0 + 10, yStat, W - 20, 32, stc, stc);
   Bar("barD", x0 + 28, yRisk + 54, W - 56, stopAmt > 0 ? -pnl / stopAmt : 0.0);
   Bar("barM", x0 + 28, yRisk + 90, W - 56, mlim > 0 ? -mp / mlim : 0.0);
   //--- en-tête
   Lbl("t1", x0 + P, y0 + 7, "FVG-D1  ·  OR", C_GOLD, fs + 5, "Segoe UI Semibold");
   Lbl("t2", x0 + P, y0 + 32, "Axi " + (real ? "RÉEL " : "DÉMO ") + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "   ·   " +
       HM(NowUTC()) + " UTC   ·   solde " + Mo(bal), C_MUTED, fs - 1);
   string stTxt = ok ? "● PRÊT" : g_has ? "● BLOQUÉ" : "● EN VEILLE";
   color  stBg  = ok ? C_GREEN_BG : g_has ? C_AMBER_BG : C_GREY;
   color  stFg  = ok ? C_GREEN : g_has ? C_AMBER : C_MUTED;
   PillR("pSt", x0 + W - 110, y0 + 14, stTxt, stBg, stFg);
   Btn("bView", x0 + W - 100, y0 + 12, 88, 28, "JOURNAL", C_GREY, clrWhite);
   //--- marché
   Lbl("mH", x0 + P, yMk, "MARCHÉ", C_MUTED, fs - 1, "Segoe UI Semibold");
   Lbl("mP", x0 + P, yMk + 16, Px(bid), C_TXT, fs + 9, "Segoe UI Semibold");
   Lbl("mS", x0 + P + TextW(Px(bid), fs + 9, "Segoe UI Semibold") + 12, yMk + 30,
       "spread " + IntegerToString(spr) + " pts" + (quiet ? "  ·  pas de cotation" : ""), quiet ? C_AMBER : C_MUTED, fs - 1);
   string tTxt = (g_trend > 0) ? "▲  HAUSSIÈRE · achats" : (g_trend < 0) ? "▼  BAISSIÈRE · ventes" : "●  SANS TENDANCE";
   color  tBg  = (g_trend > 0) ? C_GREEN_BG : (g_trend < 0) ? C_RED_BG : C_GREY;
   color  tFg  = (g_trend > 0) ? C_GREEN : (g_trend < 0) ? C_RED : C_MUTED;
   PillR("pT", x0 + W - P, yMk + 20, tTxt, tBg, tFg);
   bool calm = (InpMinVolPct > 0 && g_vol > 0 && g_vol < InpMinVolPct);
   Lbl("mE", x0 + P, yMk + 56, "EMA20 " + DoubleToString(g_e20, 1) + "  ·  EMA50 " + DoubleToString(g_e50, 1) +
       "  ·  ATR M15 " + DoubleToString(g_atr, 2) + " $", C_MUTED, fs - 1);
   string a1 = (g_trH1 > 0) ? "▲" : (g_trH1 < 0) ? "▼" : "?";
   string a4 = (g_trH4 > 0) ? "▲" : (g_trH4 < 0) ? "▼" : "?";
   Lbl("mV", x0 + P, yMk + 74, "Volatilité jour " + DoubleToString(g_vol, 2) + " %" +
       (InpMinVolPct > 0 ? (calm ? " < " : " ≥ ") + DoubleToString(InpMinVolPct, 1) + " %" : "") +
       "   ·   H1 " + a1 + "   ·   H4 " + a4, calm ? C_AMBER : C_MUTED, fs - 1);
   string pr = "Mode " + (InpMode == MODE_PRUDENT ? "PRUDENT" : InpMode == MODE_ACTIF ? "ACTIF" : InpMode == MODE_STANDARD ? "STANDARD" :
                          InpMode == MODE_MIXTE ? "MIXTE" : "PERSO") +
               " · FVG " + DoubleToString(g_minFVG, 1) + (g_bos ? " + BOS" : "") + (g_tH1 ? " + H1" : "") + (g_tH4 ? " + H4" : "") +
               (g_partR > 0 ? " · moitié +" + DoubleToString(g_partR, 0) + "R" : "") +
               (g_hold > 0 ? " · " + IntegerToString(g_hold) + " h max" : "");
   Lbl("mR", x0 + P, yMk + 92, pr, C_MUTED, fs - 1);
   //--- signal
   Lbl("sH", x0 + 28, ySig + 10, "SIGNAL", C_MUTED, fs - 1, "Segoe UI Semibold");
   if(g_has)
     {
      Sig      g    = g_best;
      color    sc   = (g.s > 0) ? C_GREEN : C_RED;
      double   lots = LotsFor(g);
      double   risk = lots * LossPerLot(g.s, g.entry, g.sl);
      datetime expT = g.t + InpMaxAgeBars * 900;
      long     left = (long)expT - (long)TimeTradeServer();
      Lbl("sB", x0 + 28, ySig + 28, (g.s > 0 ? "▲  BUY LIMIT   " : "▼  SELL LIMIT   ") + Px(g.entry), sc, fs + 5, "Segoe UI Semibold");
      Lbl("sT", x0 + W - 28, ySig + 12, "bougie " + HM(ToUTC(g.t)) + " UTC" + (InpMode == MODE_MIXTE ? (g.q < 1.0 ? " · demi-risque" : " · risque plein") : ""),
          C_MUTED, fs - 1, "Segoe UI", ANCHOR_RIGHT_UPPER);
      Lbl("s1", x0 + 28, ySig + 64, "SL  " + Px(g.sl) + "  (" + DoubleToString(g.dS, 2) + " $)", C_TXT, fs);
      Lbl("s2", x0 + 205, ySig + 64, "TP  " + Px(g.tp) + "  (" + DoubleToString(InpRR, 0) + "R)", C_TXT, fs);
      Lbl("s3", x0 + W - 28, ySig + 64, "expire " + HM(ToUTC(expT)) + (left > 0 ? " · " + Dur(left) : " · expiré"), C_TXT, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
      Lbl("s4", x0 + 28, ySig + 86, "Paliers   " + Px(g.be) + " → entrée  ·  " + Px(g.entry + g.s * 2 * g.dS) + " → +1R  ·  " +
          Px(g.entry + g.s * 3 * g.dS) + " → +2R", C_MUTED, fs - 1);
      if(lots > 0)
         Lbl("s5", x0 + 28, ySig + 106, "Lot " + DoubleToString(lots, 2) + "   ·   risque " + Mo(risk) + "   ·   objectif +" + Mo(risk * InpRR), C_TXT, fs, "Segoe UI Semibold");
      else
         Lbl("s5", x0 + 28, ySig + 106, "Lot minimum trop risqué pour le capital", C_AMBER, fs, "Segoe UI Semibold");
      Lbl("s6", x0 + W - 28, ySig + 108, (g.room > 1e6) ? "liquidité libre" : "swing à " + DoubleToString(g.room, 1) + "R", C_MUTED, fs - 1, "Segoe UI", ANCHOR_RIGHT_UPPER);
     }
   else
     {
      Lbl("sB", x0 + 28, ySig + 28, (g_trend == 0) ? "Pas de tendance D1 : aucun trade" : "Aucun signal pour l'instant", C_TXT, fs + 3, "Segoe UI Semibold");
      int yy = ySig + 58;
      if(watch)
        {
         Lbl("s1", x0 + 28, yy, g_bos ? (g_trend < 0 ? "Attendre : clôture M15 sous " + Px(g_lo10) : "Attendre : clôture M15 au-dessus de " + Px(g_hi10)) + " (BOS)"
             : (g_trend < 0 ? "Attendre : une bougie M15 baissière forte" : "Attendre : une bougie M15 haussière forte"), C_MUTED, fs - 1);
         Lbl("s2", x0 + 28, yy + 18, "avec un FVG d'au moins " + DoubleToString(g_minFVG * g_atr, 2) + " $", C_MUTED, fs - 1);
         yy += 40;
        }
      if(info)
         Lbl("s3", x0 + 28, yy, g_info, C_MUTED, fs - 1);
     }
   //--- risque et règles
   Lbl("rH", x0 + 28, yRisk + 10, "RISQUE & RÈGLES", C_MUTED, fs - 1, "Segoe UI Semibold");
   Lbl("rA", x0 + 28, yRisk + 32, "Aujourd'hui", C_TXT, fs);
   Lbl("rAv", x0 + W - 28, yRisk + 32, StringFormat("%+.2f ", pnl) + CurSym() + "   /   limite -" + Mo(stopAmt) + (stopHit ? "   ATTEINT" : ""),
       stopHit ? C_RED : C_TXT, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   Lbl("rM", x0 + 28, yRisk + 68, "Ce mois", C_TXT, fs);
   Lbl("rMv", x0 + W - 28, yRisk + 68, StringFormat("%+.2f ", mp) + CurSym() + "   /   limite -" + Mo(mlim) + (mHit ? "   ATTEINTE" : ""),
       mHit ? C_RED : C_TXT, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   bool dd = InDrawdown();
   Lbl("rR", x0 + 28, yRisk + 104, "Risque par trade", C_TXT, fs);
   Lbl("rRv", x0 + W - 28, yRisk + 104, (InpFixedLot > 0) ? "lot fixe " + DoubleToString(InpFixedLot, 2) :
       DoubleToString(EffRiskPct(), 2) + " %  ≈  " + Mo(bal * EffRiskPct() / 100.0) + (dd ? "   (réduit)" : ""),
       dd ? C_AMBER : C_TXT, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   Lbl("rT", x0 + 28, yRisk + 124, "Trades FVG du jour", C_TXT, fs);
   Lbl("rTv", x0 + W - 28, yRisk + 124, IntegerToString(nF) + " / " + IntegerToString(InpMaxPerDay) + "   ·   pertes de suite " + IntegerToString(streak) +
       (pause ? "   PAUSE → " + HM(ToUTC(PauseEnd(lastLoss))) : ""), pause ? C_AMBER : C_TXT, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   string nTxt = "aucune dans la liste";
   color  nClr = C_AMBER;
   int    nw   = NewsWindow();
   if(nw >= 0)
      nTxt = g_newsN[nw] + " " + HM(g_newsT[nw]) + " UTC : pas de nouvel ordre";
   else
     {
      int nn = NewsNext();
      if(nn >= 0)
        {
         nTxt = g_newsN[nn] + "  " + TimeToString(g_newsT[nn], TIME_DATE | TIME_MINUTES) + " UTC  ·  dans " + Dur((long)g_newsT[nn] - (long)NowUTC());
         nClr = C_TXT;
        }
     }
   Lbl("rN", x0 + 28, yRisk + 144, "Prochaine annonce", C_TXT, fs);
   Lbl("rNv", x0 + W - 28, yRisk + 144, nTxt, nClr, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   UpdateTestStats();
   string tTx;
   color  tCl = C_TXT;
   if(InpTestStopDD > 0 && g_tDD >= InpTestStopDD)
     {
      tTx = "ARRÊTÉ : baisse " + DoubleToString(g_tDD, 1) + " % (limite " + DoubleToString(InpTestStopDD, 0) + " %)";
      tCl = C_RED;
     }
   else
      if(g_tN >= InpTestTrades)
        {
         tTx = "TERMINÉ : " + StringFormat("%+.2f ", g_tNet) + CurSym() + (g_tNet > 0 ? "  →  positif" : "  →  à revoir");
         tCl = (g_tNet > 0) ? C_GREEN : C_RED;
        }
      else
         tTx = IntegerToString(g_tN) + " / " + IntegerToString(InpTestTrades) + "   ·   " + StringFormat("%+.2f ", g_tNet) + CurSym() +
               "   ·   baisse " + DoubleToString(g_tDD, 1) + " %";
   Lbl("rX", x0 + 28, yRisk + 164, "Test " + IntegerToString(InpTestTrades) + " trades", C_TXT, fs);
   Lbl("rXv", x0 + W - 28, yRisk + 164, tTx, tCl, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   color gCl = (g_slipAvg > 2 * InpSlipWarn) ? C_RED : (g_slipAvg > InpSlipWarn) ? C_AMBER : C_TXT;
   Lbl("rG", x0 + 28, yRisk + 184, "Glissement sur SL/TP", C_TXT, fs);
   Lbl("rGv", x0 + W - 28, yRisk + 184, (g_slipN > 0) ? "moyenne " + DoubleToString(g_slipAvg, 2) + " $   ·   max " + DoubleToString(g_slipMax, 2) +
       " $   ·   " + IntegerToString(g_slipN) + " sorties" : "pas encore de sortie mesurée", gCl, fs, "Segoe UI", ANCHOR_RIGHT_UPPER);
   //--- ordres et positions
   Lbl("pH", x0 + 28, yPos + 10, "SUR " + _Symbol + "   (" + IntegerToString(ex) + ")", C_MUTED, fs - 1, "Segoe UI Semibold");
   if(nl == 0)
      Lbl("p0", x0 + 28, yPos + 30, "Aucun ordre ni position", C_MUTED, fs);
   for(int j = 0; j < nl; j++)
      Lbl("p" + IntegerToString(j), x0 + 28, yPos + 30 + 18 * j, ls[j], C_TXT, fs - 1);
   //--- état et boutons
   Lbl("stT", x0 + 28, yStat + 8, ok ? "✔   Prêt : clique sur ENVOYER" : "●   " + why, clrWhite, fs, "Segoe UI Semibold");
   color  sb = C_GREY;
   string st = "ENVOYER L'ORDRE";
   if(ok)
     {
      sb = (g_best.s > 0) ? C_GREEN : C_RED;
      st = (g_best.s > 0) ? "▲  ENVOYER L'ACHAT" : "▼  ENVOYER LA VENTE";
     }
   Btn("bSend", x0 + 10, yBtn, 250, 36, st, sb, clrWhite);
   Btn("bCancel", x0 + 268, yBtn, 150, 36, "ANNULER MES ORDRES", C_GREY, clrWhite);
   Btn("bAuto", x0 + 426, yBtn, 104, 36, g_auto ? "AUTO  ON" : "AUTO  OFF", g_auto ? C_GOLD : C_GREY, g_auto ? C'20,20,20' : clrWhite);
   bool algo = (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0 && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0);
   Lbl("foot", x0 + P, yFoot + 4, algo ? "Algo Trading activé   ·   robot n° " + IntegerToString(InpMagic) : "Algo Trading DÉSACTIVÉ : active-le dans MT5",
       algo ? C_MUTED : C_RED, fs - 2);
   Lbl("footG", x0 + W - P, yFoot + 4, GuardTxt(), C_MUTED, fs - 2, "Segoe UI", ANCHOR_RIGHT_UPPER);
   g_panelH = H;
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Pause après plusieurs pertes de suite (règle de discipline n° 4) |
//+------------------------------------------------------------------+
datetime PauseEnd(const datetime lastLoss)
  {
   return (datetime)((long)lastLoss + (long)InpPauseHours * 3600);
  }

bool PauseActive(const int streak, const datetime lastLoss)
  {
   if(InpPauseLosses <= 0 || InpPauseHours <= 0 || lastLoss == 0)
      return false;
   return (streak >= InpPauseLosses && TimeTradeServer() < PauseEnd(lastLoss));
  }

//+------------------------------------------------------------------+
//| Journal : trades clos reconstruits depuis l'historique Axi        |
//+------------------------------------------------------------------+
string ReasonTxt(const long r)
  {
   if(r == DEAL_REASON_SL)
      return "SL";
   if(r == DEAL_REASON_TP)
      return "TP";
   if(r == DEAL_REASON_SO)
      return "stop out";
   if(r == DEAL_REASON_EXPERT)
      return "robot";
   return "main";
  }

string DM(const datetime utc)
  {
   string s = TimeToString(utc, TIME_DATE | TIME_MINUTES);   // AAAA.MM.JJ HH:MM
   return StringSubstr(s, 8, 2) + "." + StringSubstr(s, 5, 2) + " " + StringSubstr(s, 11, 5);
  }

string Num(const double v, const int d)
  {
   string s = DoubleToString(v, d);
   StringReplace(s, ".", ",");
   return s;
  }

int SymDigits(const string sym)
  {
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return (dg > 0) ? dg : 5;
  }

int FindTrd(const Trd &tr[], const long pid)
  {
   for(int k = ArraySize(tr) - 1; k >= 0; k--)
      if(tr[k].pid == pid)
         return k;
   return -1;
  }

void BuildTrades(const datetime fromSrv, Trd &tr[])
  {
   ArrayResize(tr, 0);
   datetime selFrom = 0;
   if((long)fromSrv > 30 * 86400)
      selFrom = (datetime)((long)fromSrv - 30 * 86400);   // pour retrouver l'entrée des trades longs
   if(!HistorySelect(selFrom, TimeTradeServer() + 3600))
      return;
   int tot = HistoryDealsTotal();
   for(int i = 0; i < tot; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long typ = HistoryDealGetInteger(d, DEAL_TYPE);
      if(typ != DEAL_TYPE_BUY && typ != DEAL_TYPE_SELL)
         continue;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      long ent = HistoryDealGetInteger(d, DEAL_ENTRY);
      int  k   = FindTrd(tr, pid);
      if(k < 0)
        {
         k = ArraySize(tr);
         ArrayResize(tr, k + 1);
         tr[k].pid  = pid;
         tr[k].tin  = 0;
         tr[k].tout = 0;
         tr[k].sym  = HistoryDealGetString(d, DEAL_SYMBOL);
         tr[k].s    = 0;
         tr[k].vol  = 0;
         tr[k].vout = 0;
         tr[k].pin  = 0;
         tr[k].pout = 0;
         tr[k].net  = 0;
         tr[k].org  = "manuel";
         tr[k].why  = "";
        }
      double vol = HistoryDealGetDouble(d, DEAL_VOLUME);
      double px  = HistoryDealGetDouble(d, DEAL_PRICE);
      tr[k].net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(ent == DEAL_ENTRY_IN)
        {
         if(tr[k].tin == 0)
           {
            tr[k].tin = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
            tr[k].s   = (typ == DEAL_TYPE_BUY) ? 1 : -1;
            tr[k].org = Origin(HistoryDealGetInteger(d, DEAL_MAGIC), HistoryDealGetString(d, DEAL_COMMENT));
           }
         if(tr[k].vol + vol > 0)
            tr[k].pin = (tr[k].pin * tr[k].vol + px * vol) / (tr[k].vol + vol);
         tr[k].vol += vol;
        }
      else
        {
         if(tr[k].s == 0)
            tr[k].s = (typ == DEAL_TYPE_BUY) ? -1 : 1;
         if(tr[k].vout + vol > 0)
            tr[k].pout = (tr[k].pout * tr[k].vout + px * vol) / (tr[k].vout + vol);
         tr[k].vout += vol;
         tr[k].tout  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         tr[k].why   = ReasonTxt(HistoryDealGetInteger(d, DEAL_REASON));
        }
     }
  }

// indices des trades clos depuis fromSrv, triés par heure de clôture
int ClosedSorted(const Trd &tr[], const datetime fromSrv, int &idx[])
  {
   ArrayResize(idx, 0);
   int n = 0;
   for(int k = 0; k < ArraySize(tr); k++)
     {
      if(tr[k].tout == 0 || tr[k].tout < fromSrv)
         continue;
      if(tr[k].vol > 0 && tr[k].vout < tr[k].vol - 1e-8)
         continue;   // encore ouvert
      ArrayResize(idx, n + 1);
      idx[n] = k;
      n++;
     }
   for(int a = 1; a < n; a++)
     {
      int v = idx[a];
      int b = a - 1;
      while(b >= 0 && tr[idx[b]].tout > tr[v].tout)
        {
         idx[b + 1] = idx[b];
         b--;
        }
      idx[b + 1] = v;
     }
   return n;
  }

void JRow(const string k, const string v, const color c)
  {
   int n = ArraySize(g_jk);
   ArrayResize(g_jk, n + 1);
   ArrayResize(g_jv, n + 1);
   ArrayResize(g_jc, n + 1);
   g_jk[n] = k;
   g_jv[n] = v;
   g_jc[n] = c;
  }

void JLine(const string l, const string r, const color c)
  {
   int n = ArraySize(g_jL);
   ArrayResize(g_jL, n + 1);
   ArrayResize(g_jR, n + 1);
   ArrayResize(g_jLc, n + 1);
   g_jL[n]  = l;
   g_jR[n]  = r;
   g_jLc[n] = c;
  }

void ComputeJournal()
  {
   g_jLast = TimeLocal();
   ArrayResize(g_jk, 0);
   ArrayResize(g_jv, 0);
   ArrayResize(g_jc, 0);
   ArrayResize(g_jL, 0);
   ArrayResize(g_jR, 0);
   ArrayResize(g_jLc, 0);
   datetime nowS  = TimeTradeServer();
   datetime fromS = 0;
   string   per   = "tout l'historique";
   if(g_period == 0)
     {
      fromS = DayStartSrv();
      per   = "aujourd'hui (jour UTC)";
     }
   if(g_period == 1)
     {
      fromS = (datetime)((long)nowS - 7 * 86400);
      per   = "7 derniers jours";
     }
   if(g_period == 2)
     {
      fromS = (datetime)((long)nowS - 30 * 86400);
      per   = "30 derniers jours";
     }
   Trd tr[];
   BuildTrades(fromS, tr);
   int idx[];
   int n = ClosedSorted(tr, fromS, idx);

   double sum = 0, sw = 0, sloss = 0, best = 0, worst = 0;
   int    nw = 0, nl = 0, run = 0, maxRun = 0;
   double oN[3];
   double oS[3];
   for(int o = 0; o < 3; o++)
     {
      oN[o] = 0;
      oS[o] = 0;
     }
   string syms[];
   double symS[];
   int    symN[];
   for(int a = 0; a < n; a++)
     {
      int    k = idx[a];
      double v = tr[k].net;
      sum += v;
      if(v > 0)
        {
         nw++;
         sw += v;
         run = 0;
        }
      else
         if(v < 0)
           {
            nl++;
            sloss += v;
            run++;
            if(run > maxRun)
               maxRun = run;
           }
      if(a == 0 || v > best)
         best = v;
      if(a == 0 || v < worst)
         worst = v;
      int o = 2;
      if(tr[k].org == "robot")
         o = 0;
      if(tr[k].org == "Claude")
         o = 1;
      oN[o] += 1;
      oS[o] += v;
      int q = -1;
      for(int z = 0; z < ArraySize(syms); z++)
         if(syms[z] == tr[k].sym)
           {
            q = z;
            break;
           }
      if(q < 0)
        {
         q = ArraySize(syms);
         ArrayResize(syms, q + 1);
         ArrayResize(symS, q + 1);
         ArrayResize(symN, q + 1);
         syms[q] = tr[k].sym;
         symS[q] = 0;
         symN[q] = 0;
        }
      symS[q] += v;
      symN[q]++;
     }

   JRow("Période", per, C_TXT);
   if(n == 0)
      JRow("Trades clos", "aucun sur la période", C_MUTED);
   else
     {
      JRow("Trades clos", IntegerToString(n) + " · gagnants " + IntegerToString(nw) + " (" + DoubleToString(100.0 * nw / n, 0) + " %) · perdants " + IntegerToString(nl), C_TXT);
      JRow("Résultat net", StringFormat("%+.2f ", sum) + CurSym(), (sum >= 0) ? C_GREEN : C_RED);
      string gm = (nw > 0) ? "+" + Mo(sw / nw) : "-";
      string pm = (nl > 0) ? Mo(sloss / nl) : "-";
      JRow("Gain / perte moy.", gm + "  /  " + pm, C_TXT);
      JRow("Profit factor", (sloss < 0) ? DoubleToString(sw / -sloss, 2) : "-", C_TXT);
      JRow("Meilleur / pire", StringFormat("%+.2f / %+.2f ", best, worst) + CurSym(), C_TXT);
      JRow("Série perdante max", IntegerToString(maxRun) + " trades", (maxRun >= 4) ? C_AMBER : C_TXT);
      string onm[3] = {"Robot (méthode)", "Claude", "Manuel"};
      for(int o = 0; o < 3; o++)
         if(oN[o] > 0)
            JRow(onm[o], IntegerToString((int)oN[o]) + " trades · " + StringFormat("%+.2f ", oS[o]) + CurSym(), (oS[o] >= 0) ? C_GREEN : C_RED);
      int  ns = ArraySize(syms);
      bool used[];
      ArrayResize(used, ns);
      for(int z = 0; z < ns; z++)
         used[z] = false;
      for(int r = 0; r < 3 && r < ns; r++)
        {
         int bi = -1;
         for(int z = 0; z < ns; z++)
            if(!used[z] && (bi < 0 || MathAbs(symS[z]) > MathAbs(symS[bi])))
               bi = z;
         if(bi < 0)
            break;
         used[bi] = true;
         JRow((r == 0) ? "Par marché" : "", syms[bi] + " · " + IntegerToString(symN[bi]) + " trades · " + StringFormat("%+.2f ", symS[bi]) + CurSym(),
              (symS[bi] >= 0) ? C_GREEN : C_RED);
        }
     }

   // règles du jour
   int      nF       = 0;
   int      streak   = 0;
   datetime lastLoss = 0;
   double   pd       = TodayPnl(nF, streak, lastLoss);
   double   stopAmt  = AccountInfoDouble(ACCOUNT_BALANCE) * InpDailyStopPct / 100.0;
   bool     stopHit  = (InpDailyStopPct > 0 && pd <= -stopAmt);
   bool     pause    = PauseActive(streak, lastLoss);
   JRow("Aujourd'hui", StringFormat("%+.2f ", pd) + CurSym() + " · stop -" + Mo(stopAmt) + (stopHit ? " : ATTEINT" : " : ok"), stopHit ? C_RED : C_TXT);
   UpdateTestStats();
   JRow("Glissement SL/TP", (g_slipN > 0) ? "moyenne " + DoubleToString(g_slipAvg, 2) + " $ · max " + DoubleToString(g_slipMax, 2) + " $ (" + IntegerToString(g_slipN) + ")" : "-",
        (g_slipAvg > InpSlipWarn) ? C_AMBER : C_TXT);
   JRow("Test " + IntegerToString(InpTestTrades) + " trades", IntegerToString(g_tN) + " / " + IntegerToString(InpTestTrades) + " · " + StringFormat("%+.2f ", g_tNet) + CurSym() +
        " · baisse " + DoubleToString(g_tDD, 1) + " %", C_TXT);
   JRow("Pertes de suite", IntegerToString(streak) + (pause ? " : pause jusqu'à " + HM(ToUTC(PauseEnd(lastLoss))) + " UTC" : ""), pause ? C_AMBER : C_TXT);

   // derniers trades
   for(int a = n - 1; a >= 0 && a >= n - 10; a--)
     {
      int    k  = idx[a];
      int    dg = SymDigits(tr[k].sym);
      double vl = (tr[k].vol > 0) ? tr[k].vol : tr[k].vout;
      string l  = DM(ToUTC(tr[k].tout)) + "  " + tr[k].sym + "  " + ((tr[k].s > 0) ? "achat " : "vente ") + DoubleToString(vl, 2);
      string r  = ((tr[k].pin > 0) ? DoubleToString(tr[k].pin, dg) : "?") + " → " + DoubleToString(tr[k].pout, dg) + " · " +
                  StringFormat("%+.2f ", tr[k].net) + CurSym() + " · " + tr[k].why + " · " + tr[k].org;
      JLine(l, r, (tr[k].net >= 0) ? C_GREEN : C_RED);
     }
   if(n == 0)
      JLine("aucun trade clos sur la période", "", C_MUTED);
  }

void ExportCsv()
  {
   Trd tr[];
   BuildTrades(0, tr);
   int idx[];
   int n  = ClosedSorted(tr, 0, idx);
   string fn = "Journal_FVG_D1.csv";
   int h  = FileOpen(fn, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      MessageBox("Impossible de créer le fichier (erreur " + IntegerToString(GetLastError()) + ").", "FVG-D1", MB_OK | MB_ICONERROR);
      return;
     }
   FileWriteString(h, "ouverture_utc;cloture_utc;symbole;sens;lots;prix_entree;prix_sortie;resultat_" + AccountInfoString(ACCOUNT_CURRENCY) +
                   ";sortie_par;origine;position\r\n");
   for(int a = 0; a < n; a++)
     {
      int    k  = idx[a];
      int    dg = SymDigits(tr[k].sym);
      double vl = (tr[k].vol > 0) ? tr[k].vol : tr[k].vout;
      string tin = (tr[k].tin > 0) ? TimeToString(ToUTC(tr[k].tin), TIME_DATE | TIME_MINUTES) : "";
      FileWriteString(h, tin + ";" + TimeToString(ToUTC(tr[k].tout), TIME_DATE | TIME_MINUTES) + ";" + tr[k].sym + ";" +
                      ((tr[k].s > 0) ? "achat" : "vente") + ";" + Num(vl, 2) + ";" + Num(tr[k].pin, dg) + ";" + Num(tr[k].pout, dg) + ";" +
                      Num(tr[k].net, 2) + ";" + tr[k].why + ";" + tr[k].org + ";" + IntegerToString(tr[k].pid) + "\r\n");
     }
   FileClose(h);
   MessageBox(IntegerToString(n) + " trades exportés dans :\n" + TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + fn +
              "\n\nOuvre-le avec Excel, ou envoie-le à Claude pour l'analyse.", "FVG-D1", MB_OK | MB_ICONINFORMATION);
  }

void DrawJournal()
  {
   int x  = InpX;
   int y0 = InpY;
   int w  = 540;
   if(g_jLast == 0)
      ComputeJournal();
   Rect("bg", x, y0, w, g_panelH);
   int y = y0 + 8;
   Lbl("title", x + 12, y, "Journal de trading · Axi " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), C_TXT, InpFont + 2, "Segoe UI Semibold");
   Btn("bView", x + w - 100, y - 2, 88, 24, "ANALYSE", C_GREY, clrWhite);
   y += RowH() + 10;
   int i = 0;
   for(int j = 0; j < ArraySize(g_jk); j++)
      Row(i, y, g_jk[j], g_jv[j], g_jc[j]);
   for(int j = i; j < g_rows; j++)
     {
      ObjectDelete(0, N("k" + IntegerToString(j)));
      ObjectDelete(0, N("v" + IntegerToString(j)));
     }
   g_rows = i;
   y += 6;
   Lbl("jhead", x + 12, y, "Derniers trades clos (heure UTC)", C_TXT, InpFont, "Segoe UI Semibold");
   y += RowH() + 2;
   int nl = ArraySize(g_jL);
   for(int j = 0; j < nl; j++)
     {
      Lbl("jl" + IntegerToString(j), x + 12, y, g_jL[j], C_MUTED);
      Lbl("jr" + IntegerToString(j), x + 225, y, g_jR[j], g_jLc[j]);
      y += RowH();
     }
   for(int j = nl; j < g_jrows; j++)
     {
      ObjectDelete(0, N("jl" + IntegerToString(j)));
      ObjectDelete(0, N("jr" + IntegerToString(j)));
     }
   g_jrows = nl;
   y += 8;
   string pn[4] = {"JOUR", "7 JOURS", "30 JOURS", "TOUT"};
   for(int j = 0; j < 4; j++)
      Btn("bP" + IntegerToString(j), x + 12 + j * 82, y, 76, 28, pn[j], (j == g_period) ? C_AMBER : C_GREY, clrWhite);
   Btn("bExp", x + 350, y, 178, 28, "EXPORTER POUR EXCEL", C_GREY, clrWhite);
   y += 36;
   Lbl("foot", x + 12, y, "Historique du compte Axi · mis à jour toutes les 30 s", C_MUTED, InpFont - 1);
   y += RowH() + 4;
   g_panelH = y - y0;
   Rect("bg", x, y0, w, g_panelH);
   ChartRedraw();
  }

void SwitchView(const int v)
  {
   g_view = v;
   g_sig  = "";
   ObjectsDeleteAll(0, "FVGP_");
   g_rows  = 0;
   g_jrows = 0;
   if(g_view == 1)
      ComputeJournal();
   Draw();
  }

//+------------------------------------------------------------------+
//| Événements                                                       |
//+------------------------------------------------------------------+
void CheckNewBar()
  {
   datetime bt = iTime(_Symbol, PERIOD_M15, 0);
   bool wait = ((g_tH1 && g_trH1 == 0) || (g_tH4 && g_trH4 == 0)) && TimeLocal() - g_trWait >= 5;
   if(bt == g_lastBar && g_dataOk && !wait)
      return;
   bool sameBar = (bt == g_lastBar);
   if(wait)
      g_trWait = TimeLocal();   // EMA H1/H4 pas encore calculées : on réessaie toutes les 5 s
   g_lastBar = bt;
   Rebuild();
   bool ready = !((g_tH1 && g_trH1 == 0) || (g_tH4 && g_trH4 == 0));
   if(g_warm && ready)
     {
      g_warm = false;
      if(sameBar)
        {
         g_notified = g_has ? g_best.t : 0;   // signal déjà présent au démarrage : pas d'alerte en double
         return;
        }
     }
   if(g_has && g_best.t != g_notified)
     {
      g_notified = g_best.t;
      Notify("FVG-D1 " + _Symbol + " : nouveau signal " + (g_best.s > 0 ? "BUY LIMIT " : "SELL LIMIT ") + Px(g_best.entry) +
             " SL " + Px(g_best.sl) + " TP " + Px(g_best.tp) + (g_auto ? " (envoi automatique)" : " : clique sur ENVOYER."));
     }
  }

int OnInit()
  {
   ParseNews();
   UpdOffset();
   //--- réglages effectifs selon le mode (les paramètres « Mode personnalisé » ne servent qu'en mode PERSO)
   g_minFVG = InpMinFVG; g_bos = InpRequireBOS; g_tH1 = InpTrendH1; g_tH4 = InpTrendH4;
   g_partR  = InpPartialR; g_hold = InpMaxHoldHours; g_fri = InpFridayStop;
   if(InpMode == MODE_STANDARD)
     {
      g_minFVG = 0.5; g_bos = true; g_tH1 = false; g_tH4 = false; g_partR = 0.0; g_hold = 24; g_fri = InpStdFriday;
     }
   if(InpMode == MODE_PRUDENT)
     {
      g_minFVG = 0.5; g_bos = true; g_tH1 = true; g_tH4 = true; g_partR = 2.0; g_hold = 12; g_fri = 14;
     }
   if(InpMode == MODE_ACTIF)
     {
      g_minFVG = 0.2; g_bos = false; g_tH1 = false; g_tH4 = false; g_partR = 2.0; g_hold = 12; g_fri = 14;
     }
   if(InpMode == MODE_MIXTE)
     {
      g_minFVG = 0.2; g_bos = false; g_tH1 = false; g_tH4 = InpMixNeedH4; g_partR = 2.0; g_hold = 12; g_fri = 14;
     }
   g_auto = InpAutoStart;
   if(StringFind(_Symbol, "XAU") < 0)
      Print("FVG-D1 : attention, la méthode n'a été testée que sur l'or (XAUUSD).");
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);
   g_hH1a = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hH1b = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hH4a = iMA(_Symbol, PERIOD_H4, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hH4b = iMA(_Symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hH1a == INVALID_HANDLE || g_hH1b == INVALID_HANDLE || g_hH4a == INVALID_HANDLE || g_hH4b == INVALID_HANDLE)
     {
      Print("FVG-D1 : impossible de créer les moyennes H1/H4.");
      return INIT_FAILED;
     }
   if(InpMagic == 0)
     {
      Print("FVG-D1 : le numéro magique ne peut pas être 0 (le garde-fou fermerait les trades du robot).");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_guardFrom = TimeTradeServer();
   if(InpGuard != GUARD_OFF)
     {
      int old = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk > 0 && PositionSelectByTicket(tk) && GuardWatched(PositionGetString(POSITION_SYMBOL)) &&
            GuardManualOrigin(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_COMMENT)))
            old++;
        }
      Print("FVG-D1 : garde-fou actif (" + (InpGuard == GUARD_CLOSE ? "fermeture immédiate" : "alerte") + ") pour les trades manuels ouverts à partir de maintenant." +
            (old > 0 ? " " + IntegerToString(old) + " position(s) manuelle(s) déjà ouverte(s) : pas touchée(s)." : ""));
     }
   g_lastBar = 0;
   Rebuild();
   g_notified = g_has ? g_best.t : 0;   // pas d'alerte pour un signal déjà affiché au démarrage
   g_warm     = ((g_tH1 && g_trH1 == 0) || (g_tH4 && g_trH4 == 0));
   g_lastBar  = iTime(_Symbol, PERIOD_M15, 0);
   EventSetTimer(1);
   Draw();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_hH1a != INVALID_HANDLE) IndicatorRelease(g_hH1a);
   if(g_hH1b != INVALID_HANDLE) IndicatorRelease(g_hH1b);
   if(g_hH4a != INVALID_HANDLE) IndicatorRelease(g_hH4a);
   if(g_hH4b != INVALID_HANDLE) IndicatorRelease(g_hH4b);
   ObjectsDeleteAll(0, "FVGP_");
   ChartRedraw();
  }

void OnTick()
  {
   GuardManual();
   ManagePositions();
  }

void OnTimer()
  {
   UpdOffset();
   GuardManual();
   CheckNewBar();
   ManagePending();
   ManagePositions();
   if(g_auto && g_has && g_best.t != g_lastTry)
     {
      string why;
      double l;
      if(CanSend(why, l))
        {
         g_lastTry = g_best.t;   // une seule tentative par signal
         SendOrder(false);
        }
     }
   if(g_view == 1 && TimeLocal() - g_jLast >= 30)
      ComputeJournal();
   Draw();
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;
   if(StringFind(sparam, "FVGP_") != 0)
      return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   if(sparam == N("bView"))
     {
      SwitchView(g_view == 1 ? 0 : 1);
      return;
     }
   if(StringFind(sparam, N("bP")) == 0)
     {
      g_period = (int)StringToInteger(StringSubstr(sparam, StringLen(N("bP"))));
      ComputeJournal();
      Draw();
      return;
     }
   if(sparam == N("bExp"))
     {
      ExportCsv();
      Draw();
      return;
     }
   if(sparam == N("bSend"))
     {
      UpdOffset();
      Rebuild();
      SendOrder(true);
     }
   else
      if(sparam == N("bCancel"))
        {
         string q = "Annuler les ordres en attente posés par ce robot sur " + _Symbol + " ?\n(Les ordres placés par Claude ou à la main ne sont pas touchés.)";
         if(MessageBox(q, "FVG-D1", MB_YESNO | MB_ICONQUESTION) == IDYES)
            if(CancelMine("à ta demande") == 0)
               MessageBox("Aucun ordre du robot en attente.", "FVG-D1", MB_OK | MB_ICONINFORMATION);
        }
      else
         if(sparam == N("bAuto"))
           {
            if(!g_auto)
              {
               string m = "Mode automatique : le robot enverra seul chaque signal FVG-D1 sur ton compte " + (IsReal() ? "RÉEL" : "DÉMO") +
                          ", avec les mêmes règles (1 ordre à la fois, " + IntegerToString(InpMaxPerDay) +
                          " par jour, stop journalier, annonces).\nMT5 doit rester ouvert sur ce PC.\n\nActiver ?";
               if(MessageBox(m, "FVG-D1", MB_YESNO | MB_ICONWARNING) == IDYES)
                 {
                  g_auto    = true;
                  g_lastTry = 0;
                  Print("FVG-D1 : mode automatique activé.");
                 }
              }
            else
              {
               g_auto = false;
               Print("FVG-D1 : mode automatique désactivé.");
              }
           }
   Draw();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD || trans.type == TRADE_TRANSACTION_ORDER_ADD)
      GuardManual();
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   g_jLast = 0;   // le journal sera recalculé
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(GlobalVariableCheck(GvG((ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID))))
      return;   // trade manuel fermé par le garde-fou : déjà signalé
   long   ent = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   double px  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   if(ent == DEAL_ENTRY_IN)
      Notify("FVG-D1 : ordre déclenché à " + Px(px) + (InpManageSL ? ". Paliers SL gérés par le robot." : "."));
   else
      if(ent == DEAL_ENTRY_OUT || ent == DEAL_ENTRY_OUT_BY)
        {
         double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                    HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
         ulong dpid    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         bool  partial = (GlobalVariableCheck(GvP(dpid)) && HistoryDealGetInteger(trans.deal, DEAL_REASON) == DEAL_REASON_EXPERT &&
                          PositionSelectByTicket(dpid));
         Notify("FVG-D1 : " + (partial ? "demi-sortie" : "position clôturée") + " à " + Px(px) + ", résultat " + StringFormat("%+.2f ", p) + CurSym() + ".");
         g_tsLast = 0;
         UpdateTestStats();
         if(g_slipN >= 5 && g_slipAvg > InpSlipWarn)
            Notify("FVG-D1 : attention, glissement moyen " + DoubleToString(g_slipAvg, 2) + " $ sur les SL/TP (seuil " + DoubleToString(InpSlipWarn, 2) + " $).");
        }
  }
//+------------------------------------------------------------------+
