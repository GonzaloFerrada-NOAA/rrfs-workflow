#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2153,SC2012
#
# TODO, if residential wood burning emissions are turned on, we need to use the
if [[ "${CHEM_GROUPS,,}" == *rwc* ]]; then
   GRA2PES_SECTOR=total_minus_res #to not double count those emissions
   NEMO_SECTOR=all_minus_res
else
   GRA2PES_SECTOR=total
   NEMO_SECTOR=all
fi
GRA2PES_YEAR=2021
GRA2PES_VERSION=v1.0
#
NEMO_YEAR=2017
NEMO_VERSION=cb6ae7_2017gb_17j


INDIR_GRA2PES=${CHEM_INPUT}/emissions/anthro/raw/GRA2PES/${GRA2PES_SECTOR}/${GRA2PES_YEAR}${MM}/${DOW_STRING}/
INDIR_NEMO=${CHEM_INPUT}/emissions/anthro/raw/NEMO/${NEMO_SECTOR}/${NEMO_YEAR}${MM}/

OUTDIR=${DATA}
mkdir -p "${OUTDIR}"

EMISFILE_BASE_RAW1_GRA2PES=${INDIR_GRA2PES}/GRA2PES${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${GRA2PES_YEAR}${MM}_${DOW_STRING}_00to11Z.nc
EMISFILE_BASE_RAW2_GRA2PES=${INDIR_GRA2PES}/GRA2PES${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${GRA2PES_YEAR}${MM}_${DOW_STRING}_12to23Z.nc

EMISFILE_BASE_RAW_NEMO=${INDIR_NEMO}/emis_mole_${NEMO_SECTOR}_${NEMO_YEAR}${MM}_US01_cmaq_${NEMO_VERSION}_mean.ncf

INPUT_GRID=${CHEM_INPUT}/grids/domain_latlons/${ANTHRO_EMISINV}${GRA2PES_VERSION}_CONUS4km_grid_info.nc

EMISFILE1_GRA2PES=${OUTDIR}/GRA2PES${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${MESH_NAME}_00to11Z.nc
EMISFILE2_GRA2PES=${OUTDIR}/GRA2PES${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${MESH_NAME}_12to23Z.nc

EMISFILE_NEMO=${OUTDIR}/NEMO${NEMO_VERSION}_${NEMO_SECTOR}_${MESH_NAME}_00to23Z.nc

# the following 2 variable are not used
#EMISFILE1_vinterp=${ANTHROEMIS_OUTPUTDIR}/${ANTHRO_EMISINV}${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${MESH_NAME}_00to11Z_vinterp.nc
#EMISFILE2_vinterp=${ANTHROEMIS_OUTPUTDIR}/${ANTHRO_EMISINV}${GRA2PES_VERSION}_${GRA2PES_SECTOR}_${MESH_NAME}_12to23Z_vinterp.nc
#
if [[ "${ANTHRO_EMISINV,,}" == *GRA2PES* ]]; then

if [[ -r ${EMISFILE_BASE_RAW1_GRA2PES} ]] && [[ -r ${EMISFILE_BASE_RAW2_GRA2PES} ]]; then
  echo "Checking to make sure we have corner coords"
  ncdump -hv XLAT_C "${EMISFILE_BASE_RAW1_GRA2PES}"
  #shellcheck disable=SC2181
  if [[ $? -ne 0 ]]; then
    echo ".. we don't, cutting in from ${INPUT_GRID}"
    ncks -A -v XLAT_C,XLAT_M,XLONG_C,XLONG_M "${INPUT_GRID}" "${EMISFILE_BASE_RAW1_GRA2PES}"
    ncks -A -v XLAT_C,XLAT_M,XLONG_C,XLONG_M "${INPUT_GRID}" "${EMISFILE_BASE_RAW2_GRA2PES}"
  else
    echo "...we do!"
  fi
  echo "Found base emission files: ${EMISFILE_BASE_RAW1_GRA2PES} and ${EMISFILE_BASE_RAW2_GRA2PES}, will interpolate"
  # -- Start the regridding process
  mpirun -np "${nt}" python -u "${SCRIPT}"   \
             "GRA2PES" \
             "${DATA}" \
             "${INDIR_GRA2PES}" \
             "${OUTDIR}" \
             "${INTERP_WEIGHTS_DIR}" \
             "${YYYY}${MM}${DD}${HH}" \
             "${MESH_NAME}"

  if [[ ! -r ${EMISFILE1_GRA2PES} ]] || [[ ! -r ${EMISFILE2_GRA2PES} ]]; then
     echo "ERROR: Did not interpolate ${ANTHRO_EMISINV}"
     exit 1
  else
     ncpdq -O -a Time,nCells,nkanthro "${EMISFILE1_GRA2PES}" "${EMISFILE1_GRA2PES}"
     ncpdq -O -a Time,nCells,nkanthro "${EMISFILE2_GRA2PES}" "${EMISFILE2_GRA2PES}"
     ncks -O --mk_rec_dmn Time "${EMISFILE1_GRA2PES}" "${EMISFILE1_GRA2PES}"
     ncks -O --mk_rec_dmn Time "${EMISFILE2_GRA2PES}" "${EMISFILE2_GRA2PES}"
     ncks -O -6  "${EMISFILE1_GRA2PES}" "${EMISFILE1_GRA2PES}"
     ncks -O -6  "${EMISFILE2_GRA2PES}" "${EMISFILE2_GRA2PES}"
     # Vertically interpolate the emissions based on the MPAS grid
     # python ${VINTERP_SCRIPT} ${EMISFILE1} ${INIT_FILE} ${EMISFILE1_vinterp} "PM25-PRI" "h_agl" "zgrid"

     for ihour in $(seq 0 "${my_fcst_length}")
     do
         YYYY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%Y)
         MM_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%m)
         DD_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%d)
         HH_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%H)
         LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/anthro.init.${YYYY_EMIS}-${MM_EMIS}-${DD_EMIS}_${HH_EMIS}.00.00.nc
         if (( 10#${HH_EMIS} > 11 )); then
            offset=12
            EMISFILE=${EMISFILE2_GRA2PES}
         else
            offset=0
            EMISFILE=${EMISFILE1_GRA2PES}
         fi
         t_ix=$(( 10#${HH_EMIS} - 10#${offset} ))
         #
         EMISFILE_FINAL=${OUTDIR}/GRA2PES_${MESH_NAME}_${HH_EMIS}Z.nc
         # Reorder
         if [[ -r ${EMISFILE_FINAL} ]]; then
            ln -sf "${EMISFILE_FINAL}" "${LINKEDEMISFILE}"
         else
            echo "Reordering dimensions -- cell x level x time -- >  Time x Cell x Level "
            ncks -d Time,${t_ix},${t_ix} "${EMISFILE}" "${EMISFILE_FINAL}"
            echo "Created file #${ihour}/${my_fcst_length} at ${EMISFILE_FINAL}"
            ncrename -v PM25-PRI,e_ant_in_unspc_fine "${EMISFILE_FINAL}"
	    ncrename -v PM10-PRI,e_ant_in_unspc_coarse "${EMISFILE_FINAL}"
            ncrename -v HC01,e_ant_in_ch4 "${EMISFILE_FINAL}"
	    ncrename -v CO,e_ant_in_co "${EMISFILE_FINAL}"
	    ncrename -v NH3,e_ant_in_nh3 "${EMISFILE_FINAL}"
	    ncrename -v NOX,e_ant_in_nox "${EMISFILE_FINAL}"
	    ncrename -v SO2,e_ant_in_so2 "${EMISFILE_FINAL}"
            ln -sf "${EMISFILE_FINAL}" "${LINKEDEMISFILE}"
         fi
     done
  fi # Did interp succeed?
fi # Do the emission files exist
fi # Is GRA2PES listed as one of the anthro inventories?


# Now for NEMO emissions
EMISFILE_NEMO_PROCESSED=${OUTDIR}/NEMO_ANTHRO_${MESH_NAME}.nc
if [[ "${ANTHRO_EMISINV,,}" == *NEMO* ]]; then
#
if [[ -r "${EMISFILE_BASE_RAW_NEMO}" ]]; then
   srun python -u "${SCRIPT}" \
                    "NEMO_ANTHRO" \
                    "${DATA}" \
                    "${INDIR_NEMO}" \
                    "${OUTDIR}" \
                    "${INTERP_WEIGHTS_DIR}" \
                    "${YYYY}${MM}${DD}${HH}" \
                    "${MESH_NAME}"
   ncap2 -O -s 'e_ant_in_unspc_fine=PEC+POC+PMOTHR' "${EMISFILE_NEMO_PROCESSED}"  "${EMISFILE_NEMO_PROCESSED}"
   ncrename -v PMC,e_ant_in_unspc_coarse "${EMISFILE_NEMO_PROCESSED}"
fi
fi # IS NEMO listed as part of the ANTHRO EMIS inventory?

# If they are both listed, let's combine it, prioritizing NEMO
if [[ "${ANTHRO_EMISINV,,}" == *GRA2PES* ]] && [[ "${ANTHRO_EMISINV,,}" == *NEMO* ]];
     for ihour in $(seq 0 "${my_fcst_length}")
     do
         YYYY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%Y)
         MM_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%m)
         DD_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%d)
         HH_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%H)
         LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/anthro.init.${YYYY_EMIS}-${MM_EMIS}-${DD_EMIS}_${HH_EMIS}.00.00.nc
         t_ix=$(( 10#${HH_EMIS} ))
         ncks -d Time,${t_ix},${t_ix} ${EMISFILE_NEMO_PROCESSED} tmp_nemo.nc
         ncks -A -v e_ant_in_unspc_fine,e_ant_in_unspc_coarse tmp_nemo.nc ${LINKEDEMISFILE}
         rm -f tmp_nemo.nc
      done
fi




