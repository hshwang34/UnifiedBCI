# S001 motor imagery (PhysioNet EEGMMIDB)

**Public dataset, not recorded on OpenBCI Cyton+Daisy; one subject, ~22 trials per class.**

This project was converted from the PhysioNet EEG Motor Movement/Imagery Dataset
(v1.0.0, doi:10.13026/C28G6P), subject S001, runs S001R04, S001R08, S001R12 ("imagine opening and
closing left or right fist"). Channels: FC3, FC1, FC2, FC4, C5, C3, C1, Cz, C2, C4, C6, CP3, CP1, CPz, CP2, CP4 at 160 Hz, microvolts.
Every conversion step is listed in `recording.json` under `source.derivations`.

## License

The dataset is distributed under the Open Data Commons Attribution License v1.0
(ODC-BY 1.0, <https://opendatacommons.org/licenses/by/1-0/>). You are free to share,
create works from and adapt the data provided you attribute it as requested by the
licensor. This converted copy carries the same license.

## Attribution

- Schalk, G., McFarland, D.J., Hinterberger, T., Birbaumer, N., Wolpaw, J.R. (2009). EEG Motor Movement/Imagery Dataset (version 1.0.0). PhysioNet. https://doi.org/10.13026/C28G6P doi:10.13026/C28G6P
- Schalk, G., McFarland, D.J., Hinterberger, T., Birbaumer, N., Wolpaw, J.R. (2004). BCI2000: A General-Purpose Brain-Computer Interface (BCI) System. IEEE Transactions on Biomedical Engineering 51(6):1034-1043. doi:10.1109/TBME.2004.827072
- Goldberger, A.L., Amaral, L.A.N., Glass, L., Hausdorff, J.M., Ivanov, P.C., Mark, R.G., Mietus, J.E., Moody, G.B., Peng, C.-K., Stanley, H.E. (2000). PhysioBank, PhysioToolkit, and PhysioNet: Components of a New Research Resource for Complex Physiologic Signals. Circulation 101(23):e215-e220. doi:10.1161/01.CIR.101.23.e215

Converted by `worker/tools/convert_eegmmidb.py` (convert_eegmmidb.py v1).
