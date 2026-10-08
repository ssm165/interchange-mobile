# FVG-D1 — pistes d'amélioration et recommandations

## Ce qui peut vraiment améliorer, sans casser le risque

1. **Plus d'occasions, pas plus de risque par trade.** Le plus gros levier est d'ajouter des instruments peu corrélés (EURUSD, NAS100, USOIL). La méthode n'a été testée que sur l'or : chaque instrument demande son propre backtest. Cela augmente le nombre de trades sans augmenter le risque d'un trade.
2. **Un filtre de session** (Londres et New York seulement), à valider par backtest. Les signaux en session asiatique sont souvent du bruit sur l'or.
3. **Une sortie par trailing sur structure** au lieu de paliers fixes, pour laisser courir les gros mouvements. À tester : les paliers au break-even à +1R peuvent couper beaucoup de gagnants.
4. **Le compounding.** Le risque en % du solde compose déjà tout seul. 4 % par mois, c'est environ 60 % par an, ce qui est très bon si c'est tenu.
5. **Un journal par type de setup** (le bouton JOURNAL existe déjà) pour retirer les setups qui perdent de l'argent après 100 trades ou plus.

## Ce que je te conseille

- Garde 1,5 % de risque par trade. Vise **3 à 6 % par mois**, avec quelques mois négatifs.
- Fais passer d'abord les 100 trades en démo.
- Si l'avantage est confirmé, tu pourras monter à 2 % de risque, pas plus, et seulement après un résultat positif sur une centaine de trades.

## Pourquoi pas 15 à 20 % par mois

- Environ 10 trades par mois, 1,5 % de risque, espérance supposée de +0,3R par trade : 10 × 0,3 × 1,5 % ≈ 4 à 5 % par mois, si l'avantage statistique existe vraiment.
- Pour viser 15 à 20 %, il faudrait un risque de 5 à 6 % par trade. Une série de 6 à 8 pertes, normale avec environ 65 % de pertes, ferait perdre 30 à 40 % du compte.
- Les gains de 50 à 70 % faits à la main viennent presque toujours d'un risque très élevé et ne sont pas reproductibles de façon contrôlée.

Tout ajout (instrument, filtre de session, trailing) doit être validé par un backtest sur ticks réels avant d'être activé.
