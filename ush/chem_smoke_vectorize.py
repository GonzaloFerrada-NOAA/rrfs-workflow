"""
Vectorize biomass burning emissions into 1-D (sparse) arrays for MPAS.

Supported datasets:
  RAVE : 2-D gridded hourly files -> keep only cells with fires
  NGFS : already sparse (1-D) hourly files -> just select/convert variables

Author: Gonzalo A. Ferrada (gonzalo.ferrada@noaa.gov)
October 2026
"""
import argparse
import glob
import os
import re
import warnings

import numpy as np
import pandas as pd
import xarray as xr

# Per dataset:
#   hour : glob for the file of one hour (formatted with the date)
#   all  : glob for every file of that dataset in PATHIN
#   regex: pulls YYYYMMDDHH out of a file name
#   lon  : True if longitudes are 0-360 and need converting to -180..180
DATASETS = {
    'RAVE': {'hour':  'RAVE-HrlyEmiss-3km_v2r0_blend_s{:%Y%m%d%H}00*.nc',
             'all':   'RAVE-HrlyEmiss-3km_v2r0_blend_s*.nc',
             'regex': r'_s(\d{10})',
             'lon':   True},
    'NGFS': {'hour':  'ngfs_processed_{:%Y%m%d%H}*.nc',
             'all':   'ngfs_processed_*.nc',
             'regex': r'ngfs_processed_(\d{10})\d{4}',
             'lon':   False},
}

# Output variables that don't change with time -> bb_pt.stack_groups.init.nc
# (only those present in the table are written). Everything else goes to the
# hourly smoke.init.retro.*.nc files
STATIC = ['BBLG', 'BBLT', 'area', 'fire_type']

# Dimension names in the output files
DIM_PT = 'nbb_pt'
DIM_K  = 'nkwildfire'
STRLEN = 64                 # length of the xtime character dimension (StrLen)

# fire_type placeholder for datasets that don't provide it (e.g. RAVE).
# Written to the static file so the model always finds the variable
FIRE_TYPE_FILL = 99
FIRE_TYPE_LONG = ('1:Agricultural 2:Prescribed 3:Wildfire 4:WUI 5:Industrial '
                  '6:Unknown 99:Not available')

# netCDF classic only supports these types (no int64, no unsigned, no compression)
CLASSIC_TYPES = {'float64', 'float32', 'int32', 'int16', 'int8'}

# Always show warnings, even if the same message repeats
warnings.simplefilter('always')


def readtable(table):
    """Read the mapping csv and clean it so users can edit it freely
    (e.g. in Excel, which leaves ',,,,,,,' lines when rows are deleted)."""

    vmap = pd.read_csv(table, encoding='utf-8-sig', skipinitialspace=True)
    vmap.columns = vmap.columns.str.strip()

    # Text columns: strip stray spaces; empty cells become NaN
    for c in ['vnamein', 'unitsin', 'vnameout', 'long_name', 'unitsout', 'datatype']:
        if c in vmap:
            vmap[c] = vmap[c].astype('string').str.strip().replace('', pd.NA)

    # Drop rows without an input or output variable name (blank/comma-only lines)
    nrow = len(vmap)
    vmap = vmap.dropna(subset=['vnamein', 'vnameout']).reset_index(drop=True)
    if len(vmap) < nrow:
        warnings.warn(f'{nrow - len(vmap)} empty row(s) in {table} ignored')

    # Fill optional cells with safe defaults
    vmap['long_name']  = vmap['long_name'].fillna(vmap['vnameout'])
    vmap['unitsout']   = vmap['unitsout'].fillna('')
    vmap['datatype']   = vmap['datatype'].fillna('float32')
    vmap['conversion'] = vmap['conversion'].fillna(1.0)

    # Variables the code needs no matter what else the user keeps
    missing = {'BBLG', 'BBLT', 'area'} - set(vmap.vnameout)
    if missing:
        raise ValueError(f'{table} must include output variables {sorted(missing)}')
    bad = sorted(set(vmap.datatype) - CLASSIC_TYPES)
    if bad:
        raise ValueError(f'{table}: datatype {bad} not supported by netCDF classic; '
                         f'use one of {sorted(CLASSIC_TYPES)}')
    if vmap.vnameout.duplicated().any():
        dup = vmap.vnameout[vmap.vnameout.duplicated()].tolist()
        raise ValueError(f'{table} has duplicated vnameout: {dup}')

    return vmap


def checkvars(dataset, f, vmap):
    """Stop early with a clear message if the table asks for variables not in the file."""
    with xr.open_dataset(f, decode_timedelta=False) as ds:
        need   = set(vmap.vnamein) | {'FRP_MEAN'}      # FRP_MEAN is used to find fires
        missing = sorted(need - set(ds.variables))
    if missing:
        raise KeyError(f'Variables {missing} from the table are not in {dataset} file '
                       f'{os.path.basename(f)}')


def isemission(units):
    """Gas (mol) or aerosol (ug) emission, based on unitsout."""
    return ('mol' in units) or ('ug' in units)


def catalog(dataset, pathin):
    """Map every available file in pathin to its hour: {Timestamp: file}."""
    cfg = DATASETS[dataset]
    files = {}
    for f in sorted(glob.glob(f'{pathin}/{cfg["all"]}')):
        m = re.search(cfg['regex'], os.path.basename(f))
        if m:
            t = pd.Timestamp(pd.to_datetime(m.group(1), format='%Y%m%d%H'))
            files.setdefault(t, f)            # first file (sorted) wins if several per hour
    return files


def readhour(dataset, date, files, treatmissing, vmap, cache):
    """Sparse data (fire x variable) for this hour. If its file is missing:
      'next'    -> use the next available file
      'last'    -> use the last available file
      'average' -> average of the last and next available files
      None      -> stop with an error
    cache stores files already read (consecutive missing hours share neighbors)."""

    def read(t):
        f = files[t]
        if f not in cache:
            cache[f] = matrix2sparse(dataset, f, vmap)
        return cache[f]

    if date in files:
        return read(date)

    if treatmissing is None:
        raise FileNotFoundError(f'No {dataset} file found for {date:%Y-%m-%d %H}Z '
                                f'(use --treatmissing next|last|average to fill it)')

    # Nearest available hours before and after the missing one
    tlast = max((t for t in files if t < date), default=None)
    tnext = min((t for t in files if t > date), default=None)
    when  = f'{dataset} file missing for {date:%Y-%m-%d %H}Z'

    # 'average' with only one neighbor available (edge of the archive) -> use that one
    if treatmissing == 'average' and (tlast is None) != (tnext is None):
        t = tlast if tlast is not None else tnext
        warnings.warn(f'{when}; only one neighbor available for averaging, using '
                      f'{t:%Y-%m-%d %H}Z: {os.path.basename(files[t])}')
        return read(t)

    if treatmissing == 'average':
        if tlast is None:                       # no neighbors at all
            raise FileNotFoundError(f'{when} and no available files to average')
        warnings.warn(f'{when}; using average of {tlast:%Y-%m-%d %H}Z and '
                      f'{tnext:%Y-%m-%d %H}Z')
        return averagefires(read(tlast), read(tnext), vmap)

    t = tnext if treatmissing == 'next' else tlast
    if t is None:
        raise FileNotFoundError(f'{when} and no {treatmissing} available file to substitute')
    warnings.warn(f'{when}; using {treatmissing} available file ({t:%Y-%m-%d %H}Z): '
                  f'{os.path.basename(files[t])}')
    return read(t)


def averagefires(dlast, dnext, vmap):
    """Average two sparse hours on the union of their (lon, lat) points.
    Returns a 2-D array (fire x variable)."""

    # Put both hours on the same points; a fire burning in only one of them
    # gets zero in the other (so it ends up with half its value)
    d3  = stackfires([dlast, dnext], vmap)     # fire x variable x 2
    avg = d3.mean(axis=2)                      # lon, lat, area are identical in both

    # Integer (categorical) fields like fire_type can't be averaged:
    # take the last hour's value, or the next hour's where the fire wasn't burning before
    for v, dt in enumerate(vmap.datatype):
        if np.issubdtype(np.dtype(dt), np.integer):
            avg[:, v] = np.where(d3[:, v, 0] != 0, d3[:, v, 0], d3[:, v, 1])

    return avg


def matrix2sparse(dataset, f, vmap):
    """Read the variables listed in vmap from file f and keep only the cells
    (RAVE) or detections (NGFS) with FRP > 0. Returns a 2-D array (fire x variable)."""

    print(f"Reading {dataset} file: {f}")
    vnameout = list(vmap.vnameout)
    idx_lon  = vnameout.index('BBLG')
    # Input name of the area variable ('area' in RAVE, 'PIXEL_AREA' in NGFS)
    areaname = vmap.vnamein.iloc[vnameout.index('area')]

    # decode_timedelta=False: keep variables with time-like units (e.g. NGFS
    # DURATION_MAX in 'hours') as plain numbers. Otherwise xarray turns them into
    # timedelta64[ns] and the float cast below would give nanoseconds
    with xr.open_dataset(f, decode_timedelta=False) as ds:
        # Works for both: 2-D grid in RAVE (boolean mask on the grid),
        # 1-D list in NGFS (boolean mask on the detections)
        I = ds['FRP_MEAN'].values.squeeze() > 0

        # Read area up front so emissions can be divided by it no matter where
        # it sits in the csv. Kept in its input units (km2); the km2 -> m2
        # factor is folded into the 'conversion' column of each species
        area = ds[areaname].values.squeeze()[I].astype(np.float64)

        data = np.zeros((I.sum(), len(vmap)), dtype=np.float64)
        for i, row in enumerate(vmap.itertuples()):

            conv  = float(row.conversion)
            units = row.unitsout
            aux   = ds[row.vnamein].values.squeeze()[I].astype(np.float64)

            # longitude from RAVE needs to be converted to -180 to 180
            if DATASETS[dataset]['lon'] and i == idx_lon:
                aux = np.where(aux > 180, aux - 360, aux)

            if 'mol' in units:
                # Gas: kg -> mol needs division by mw [g/mol]
                # (kg * 1e3 g/kg / mw) / 3600 s / (km2 * 1e6 m2/km2) -> mol/m2/s
                # i.e. conversion = 1e3/3600/1e6 = 2.7778e-7
                mw = float(row.mw)
                if not np.isfinite(mw) or mw <= 0:
                    warnings.warn(f'Invalid mw ({row.mw}) for {row.vnameout}; set to zero')
                    continue                       # column stays zero
                data[:, i] = aux * conv / (mw * area)
            elif 'ug' in units:
                # Aerosol: (kg * 1e9 ug/kg) / 3600 s / (km2 * 1e6 m2/km2) -> ug/m2/s
                # i.e. conversion = 1e9/3600/1e6 = 0.27778
                data[:, i] = aux * conv / area
            else:
                # Non-emission fields (lon, lat, area, FRP, FRE, ...): unit scaling only
                data[:, i] = aux * conv

    # RAVE TPM is total PM, so PM2.5 is subtracted to get the coarse fraction.
    # Matched by input name so it doesn't depend on the output names or csv order
    if dataset == 'RAVE':
        vnamein = list(vmap.vnamein)
        for coarse, fine in [('TPM', 'PM25'), ('TPM_scaled', 'PM25_scaled')]:
            if coarse in vnamein and fine in vnamein:
                data[:, vnamein.index(coarse)] -= data[:, vnamein.index(fine)]

    return data


def stackfires(data, vmap):
    """Put all hours on the same set of unique (lon, lat) pairs.
    Returns a 3-D array (fire x variable x time)."""

    vnameout = list(vmap.vnameout)
    nt       = len(data)
    nvar     = len(vmap)
    idx_lon  = vnameout.index('BBLG')
    idx_lat  = vnameout.index('BBLT')
    idx_area = vnameout.index('area')
    istatic  = [idx_lon, idx_lat, idx_area]   # columns that don't change with time

    # Stack all hours and get the unique (lon, lat) pairs. np.unique(..., axis=0) returns
    # them sorted by lon (west to east), and by lat (south to north) when lon ties.
    # inv gives, for every stacked row, its position in coords
    allrows = np.concatenate(data, axis=0)
    coords, ia, inv = np.unique(allrows[:, [idx_lon, idx_lat]], axis=0,
                                return_index=True, return_inverse=True)
    inv = inv.ravel()
    # For south-to-north ordering instead, uncomment:
    # order = np.lexsort((coords[:, 0], coords[:, 1]))
    # coords, ia = coords[order], ia[order]
    # inv = np.argsort(order)[inv]
    static = allrows[ia][:, istatic]          # lon, lat, area of each unique fire
    nfire  = coords.shape[0]

    # Split inv back into hours (same role as ismember in the matlab version)
    loc = np.split(inv, np.cumsum([d.shape[0] for d in data])[:-1])

    # Build the 3-D array (fire x variable x time). Fires not burning in a given
    # hour keep their coordinates and area, but get zero for everything else
    data3d = np.zeros((nfire, nvar, nt))
    for i in range(nt):
        data3d[loc[i], :, i] = data[i]
    data3d[:, istatic, :] = static[:, :, np.newaxis]

    return data3d


def main(DATASET, DATE1, DATE2, PATHIN, PATHOUT, TABLE, TREATMISSING, DAYSSHIFT=0):

    dates = pd.date_range(DATE1, DATE2, freq='h')

    # Read and clean the table with variables
    print(f"Reading table {TABLE}")
    vmap = readtable(TABLE)

    # All files available for this dataset, indexed by hour
    files = catalog(DATASET, PATHIN)
    if not files:
        raise FileNotFoundError(f'No {DATASET} files found in {PATHIN}')

    # Check the table against one file before processing anything
    checkvars(DATASET, next(iter(files.values())), vmap)

    # Read and vectorize all data defined in the csv file from each file
    data  = []
    cache = {}                                 # file -> sparse data, avoids re-reading neighbors
    for date in dates:
        data.append(readhour(DATASET, date, files, TREATMISSING, vmap, cache))

    # Same number of fires (unique lon/lat pairs) for every hour
    data3d = stackfires(data, vmap)

    # Output data type comes from the 'datatype' column of the csv.
    # netCDF classic has no compression, so only dtype and no fill value
    encoding = {row.vnameout: {'dtype': row.datatype, '_FillValue': None}
                for row in vmap.itertuples()}

    def cast(vals, dtype):
        # Round before casting to integer types (e.g. fire_type) so 2.9999 -> 3, not 2
        if np.issubdtype(np.dtype(dtype), np.integer):
            vals = np.rint(vals)
        return vals.astype(dtype)

    def attrs(row):
        return {'long_name': row.long_name, 'units': row.unitsout}

    rows    = list(vmap.itertuples())
    istatic = [v for v, r in enumerate(rows) if r.vnameout in STATIC]
    itime   = [v for v, r in enumerate(rows) if r.vnameout not in STATIC]

    # ---- 1) Static file: one value per fire point (nbb_pt) for the whole period ----
    fileout = f'{PATHOUT}/bb_pt.stack_groups.init.nc'
    print(fileout)

    ds = xr.Dataset()
    for v in istatic:
        row  = rows[v]
        vals = data3d[:, v, 0]                 # lon, lat, area: identical for all hours
        if row.vnameout not in ('BBLG', 'BBLT', 'area'):
            # Time-varying in data3d (e.g. fire_type is 0 when not burning):
            # take the first non-zero value of each fire over the period
            series = data3d[:, v, :]
            first  = np.argmax(series != 0, axis=1)        # 0 if never non-zero
            vals   = series[np.arange(series.shape[0]), first]
        ds[row.vnameout] = xr.DataArray(cast(vals, row.datatype), dims=(DIM_PT,),
                                        attrs=attrs(row))

    # Dataset without fire_type (e.g. RAVE): add a placeholder for future development
    enc_static = {k: encoding[k] for k in ds.data_vars}
    if 'fire_type' not in ds:
        ds['fire_type'] = xr.DataArray(np.full(data3d.shape[0], FIRE_TYPE_FILL, dtype='int16'),
                                       dims=(DIM_PT,),
                                       attrs={'long_name': FIRE_TYPE_LONG, 'units': '#',
                                              'note': f'placeholder, not available in {DATASET}'})
        enc_static['fire_type'] = {'dtype': 'int16', '_FillValue': None}

    ds.to_netcdf(fileout, mode='w', format='NETCDF3_CLASSIC', encoding=enc_static)

    # ---- 2) Hourly files: FRP, FRE, emissions, ... ----
    # Emissions are (nbb_pt, kwildfire); other fields are (nbb_pt) only
    for i, date in enumerate(dates):

        # Time label of the output file: data time shifted by DAYSSHIFT days
        # (e.g. persistence: yesterday's fires labeled with today's date)
        tout    = date + pd.Timedelta(days=DAYSSHIFT)
        fileout = f'{PATHOUT}/smoke.init.retro.{tout:%Y-%m-%d_%H.%M.%S}.nc'
        print(fileout)

        ds = xr.Dataset()
        for v in itime:
            row  = rows[v]
            vals = cast(data3d[:, v, i], row.datatype)
            if isemission(row.unitsout):
                ds[row.vnameout] = xr.DataArray(vals[:, np.newaxis], dims=(DIM_PT, DIM_K),
                                                attrs=attrs(row))
            else:
                ds[row.vnameout] = xr.DataArray(vals, dims=(DIM_PT,), attrs=attrs(row))

        # Valid time of this file (MPAS needs it): Time (unlimited) and xtime
        #   Time : seconds since the valid time itself -> always 0
        #   xtime: 'YYYY-MM-DD_hh:mm:ss' as char(Time, StrLen), blank padded to 64
        label = f'{tout:%Y-%m-%d_%H:%M:%S}'.ljust(STRLEN)
        ds['Time'] = xr.DataArray(
            np.array([0.0], dtype=np.float32), dims=('Time',),
            attrs={'units': f'seconds since {tout:%Y-%m-%d %H:%M:%S}',
                   'long_name': 'CF-compliant valid time', 'standard_name': 'time'})
        # One fixed-length 64-byte string per time; xarray splits it into chars
        # along 'StrLen' on write -> char xtime(Time, StrLen)
        ds['xtime'] = xr.DataArray(
            np.array([label], dtype=f'S{STRLEN}'), dims=('Time',),
            attrs={'units': 'YYYY-MM-DD_hh:mm:ss', 'long_name': 'Model valid time'})

        enc = {k: encoding[k] for k in ds.data_vars if k in encoding}
        enc['Time']  = {'dtype': 'float32', '_FillValue': None}
        enc['xtime'] = {'dtype': 'S1', 'char_dim_name': 'StrLen', '_FillValue': None}

        ds.to_netcdf(fileout, mode='w', format='NETCDF3_CLASSIC', encoding=enc,
                     unlimited_dims=['Time'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Vectorize biomass burning emissions for MPAS')
    parser.add_argument('--dataset', type=str.upper, choices=list(DATASETS), default='RAVE',
                        help='RAVE or NGFS (case insensitive)')
    parser.add_argument('--date1',   default='2025-09-07 09:00:00')
    parser.add_argument('--date2',   default='2025-09-07 16:00:00')
    parser.add_argument('--pathin',  default='None')
    parser.add_argument('--pathout', default='None')
    parser.add_argument('--table',   default=None,
                        help='csv mapping table (default: table_vectorize_<dataset>.csv)')
    parser.add_argument('--treatmissing', type=str.lower, choices=['next', 'last', 'average'],
                        default=None,
                        help='if an hourly file is missing, use the next or last available '
                             'file, or the average of both (default: stop with an error)')
    parser.add_argument('--days-shift', type=int, default=0,
                        help='shift the time label of the hourly output files by this many '
                             'days (e.g. 1 for persistence: data of 2025-09-05_17 is written '
                             'as smoke.init.retro.2025-09-06_17.00.00.nc). Default: 0')
    args = parser.parse_args()

    table = args.table or {'RAVE': 'table_vectorize_rave.csv',
                           'NGFS': 'table_vectorize_ngfs.csv'}[args.dataset]

    main(args.dataset, args.date1, args.date2, args.pathin, args.pathout, table,
         args.treatmissing, args.days_shift)