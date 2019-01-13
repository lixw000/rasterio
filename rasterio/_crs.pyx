"""Coordinate reference systems, class and functions.
"""

include "gdal.pxi"

from abc import abstractmethod
import collections
import json
import logging

from rasterio._err import CPLE_BaseError, CPLE_NotSupportedError
from rasterio.compat import UserDict, string_types
from rasterio.errors import CRSError
from rasterio.env import env_ctx_if_needed

from rasterio._base cimport _osr_from_crs as osr_from_crs
from rasterio._base cimport _safe_osr_release
from rasterio._err cimport exc_wrap_int


log = logging.getLogger(__name__)


class _CRS(collections.Mapping):
    """CRS base class."""

    def __init__(self, initialdata=None, **kwargs):
        self._wkt = None
        if initialdata:
            self._data = dict(initialdata)
        else:
            self._data = {}
            self._data.update(**kwargs)

    def __getitem__(self, item):
        return self._data[item]

    def __iter__(self):
        return iter(self._data)

    def __len__(self):
        return len(self._data)

    def _wkt_or_proj(self):
        return self._wkt or ' '.join(['+{}={}'.format(key, val) for key, val in self._data.items()])

    @property
    def is_geographic(self):
        """Test if the CRS is a geographic coordinate reference system

        Returns
        -------
        bool
        """
        cdef OGRSpatialReferenceH osr_crs = OSRNewSpatialReference(NULL)

        try:
            osr_input = self._wkt_or_proj().encode('utf-8')
            exc_wrap_int(OSRSetFromUserInput(osr_crs, <const char *>osr_input))
            exc_wrap_int(OSRMorphFromESRI(osr_crs))
            return bool(OSRIsGeographic(osr_crs) == 1)
        except CPLE_BaseError as exc:
            raise CRSError("{}".format(str(exc)))

        finally:
            _safe_osr_release(osr_crs)

    @property
    def is_projected(self):
        """Test if the CRS is a projected coordinate reference system

        Returns
        -------
        bool
        """
        cdef OGRSpatialReferenceH osr_crs = OSRNewSpatialReference(NULL)

        try:
            osr_input = self._wkt_or_proj().encode('utf-8')
            exc_wrap_int(OSRSetFromUserInput(osr_crs, <const char *>osr_input))
            exc_wrap_int(OSRMorphFromESRI(osr_crs))
            return bool(OSRIsProjected(osr_crs) == 1)
        finally:
            _safe_osr_release(osr_crs)

    def __eq__(self, other):
        cdef OGRSpatialReferenceH osr_crs1 = NULL
        cdef OGRSpatialReferenceH osr_crs2 = NULL
        cdef int retval

        try:
            #if (
            #    isinstance(other, self.__class__) and
            #    self.data == other.data
            #):
            #    return True

            if not self or not other:
                return not self and not other

            osr_crs1 = osr_from_crs(self)
            osr_crs2 = osr_from_crs(other)
            retval = OSRIsSame(osr_crs1, osr_crs2)
            return bool(retval == 1)

        finally:
            _safe_osr_release(osr_crs1)
            _safe_osr_release(osr_crs2)

    @property
    def wkt(self):
        """An OGC WKT representation of the CRS

        Returns
        -------
        str
        """
        cdef char *srcwkt = NULL
        cdef OGRSpatialReferenceH osr = NULL

        try:
            osr = osr_from_crs(self)
            OSRExportToWkt(osr, &srcwkt)
            return srcwkt.decode('utf-8')
        finally:
            CPLFree(srcwkt)
            _safe_osr_release(osr)

    def to_epsg(self):
        """The epsg code of the CRS

        Returns
        -------
        int
        """
        cdef OGRSpatialReferenceH osr = NULL

        try:
            osr = osr_from_crs(self)
            if OSRAutoIdentifyEPSG(osr) == 0:
                epsg_code = OSRGetAuthorityCode(osr, NULL)
                return int(epsg_code.decode('utf-8'))
            else:
                return None
        finally:
            _safe_osr_release(osr)

    @classmethod
    def from_epsg(cls, code):
        """Make a CRS from an EPSG code

        Parameters
        ----------
        code : int or str
            An EPSG code. Strings will be converted to integers.

        Notes
        -----
        The input code is not validated against an EPSG database.

        Returns
        -------
        CRS
        """
        if int(code) <= 0:
            raise CRSError("EPSG codes are positive integers")
        return cls(init="epsg:%s" % code, no_defs=True)

    @classmethod
    def from_string(cls, s):
        """Make a CRS from an EPSG, PROJ, or WKT string

        Parameters
        ----------
        s : str
            An EPSG, PROJ, or WKT string.

        Returns
        -------
        CRS
        """
        if not s:
            raise CRSError("CRS is empty or invalid: {!r}".format(s))

        elif s.strip().upper().startswith('EPSG:'):
            auth, val = s.strip().split(':')
            if not val:
                raise CRSError("Invalid CRS: {!r}".format(s))
            return cls.from_epsg(val)

        elif '{' in s:
            # may be json, try to decode it
            try:
                val = json.loads(s, strict=False)
            except ValueError:
                raise CRSError('CRS appears to be JSON but is not valid')

            if not val:
                raise CRSError("CRS is empty JSON")
            else:
                return cls(**val)

        elif '+' in s and '=' in s:

            parts = [o.lstrip('+') for o in s.strip().split()]

            def parse(v):
                if v in ('True', 'true'):
                    return True
                elif v in ('False', 'false'):
                    return False
                else:
                    try:
                        return int(v)
                    except ValueError:
                        pass
                    try:
                        return float(v)
                    except ValueError:
                        return v

            items = map(
                lambda kv: len(kv) == 2 and (kv[0], parse(kv[1])) or (kv[0], True),
                (p.split('=') for p in parts))

            out = cls((k, v) for k, v in items if k in all_proj_keys)

            if not out:
                raise CRSError("CRS is empty or invalid: {}".format(s))

            return out

        else:
            return cls.from_wkt(s)

    @classmethod
    def from_wkt(cls, wkt):
        """Make a CRS from a WKT string

        Parameters
        ----------
        wkt : str
            A WKT string.

        Returns
        -------
        CRS

        """
        cdef char *prj = NULL
        cdef OGRSpatialReferenceH osr = OSRNewSpatialReference(NULL)

        if isinstance(wkt, string_types):
            b_wkt = wkt.encode('utf-8')
        else:
            raise ValueError("A string is expected")

        try:
            exc_wrap_int(OSRSetFromUserInput(osr, <const char *>b_wkt))
            exc_wrap_int(OSRMorphFromESRI(osr))
            exc_wrap_int(OSRExportToProj4(osr, &prj))
            obj = cls()
            obj._wkt = wkt

            proj_str = prj.decode('utf-8')
            parts = [o.lstrip('+') for o in proj_str.strip().split()]

            def parse(v):
                if v in ('True', 'true'):
                    return True
                elif v in ('False', 'false'):
                    return False
                else:
                    try:
                        return int(v)
                    except ValueError:
                        pass
                    try:
                        return float(v)
                    except ValueError:
                        return v

            items = map(
                lambda kv: len(kv) == 2 and (kv[0], parse(kv[1])) or (kv[0], True),
                (p.split('=') for p in parts))

            obj._data = {k: v for k, v in items if k in all_proj_keys}
            return obj
        except CPLE_BaseError as exc:
            raise CRSError("The WKT could not be parsed. {}".format(str(exc)))
        finally:
            CPLFree(prj)
            _safe_osr_release(osr)

    @classmethod
    def from_user_input(cls, value):
        """Make a CRS from various input

        Dispatches to from_epsg, from_proj, or from_string

        Parameters
        ----------
        value : obj
            A Python int, dict, or str.

        Returns
        -------
        CRS
        """
        if isinstance(value, _CRS):
            return value
        elif isinstance(value, int):
            return cls.from_epsg(value)
        elif isinstance(value, dict):
            return cls(**value)
        elif isinstance(value, string_types):
            return cls.from_string(value)
        else:
            raise CRSError("CRS is invalid: {!r}".format(value))

    def to_dict(self):
        """Convert CRS to a dict"""
        cdef OGRSpatialReferenceH osr = OSRNewSpatialReference(NULL)
        cdef char *prj = NULL

        if self._data:
            return dict(self._data)
        else:
            b_wkt = self._wkt.encode('utf-8')
            try:
                exc_wrap_int(OSRSetFromUserInput(osr, <const char *>b_wkt))
                exc_wrap_int(OSRMorphFromESRI(osr))
                exc_wrap_int(OSRExportToProj4(osr, &prj))
                proj_str = prj.decode('utf-8')
                parts = [o.lstrip('+') for o in proj_str.strip().split()]

                def parse(v):
                    if v in ('True', 'true'):
                        return True
                    elif v in ('False', 'false'):
                        return False
                    else:
                        try:
                            return int(v)
                        except ValueError:
                            pass
                        try:
                            return float(v)
                        except ValueError:
                            return v

                items = map(
                    lambda kv: len(kv) == 2 and (kv[0], parse(kv[1])) or (kv[0], True),
                    (p.split('=') for p in parts))

                return {k: v for k, v in items if k in all_proj_keys}
            except CPLE_BaseError as exc:
                raise CRSError("The WKT could not be parsed. {}".format(str(exc)))
            finally:
                CPLFree(prj)
                _safe_osr_release(osr)

# Below is the big list of PROJ4 parameters from
# http://trac.osgeo.org/proj/wiki/GenParms.
# It is parsed into a list of parameter keys ``all_proj_keys``.

_param_data = """
+a         Semimajor radius of the ellipsoid axis
+alpha     ? Used with Oblique Mercator and possibly a few others
+axis      Axis orientation (new in 4.8.0)
+b         Semiminor radius of the ellipsoid axis
+datum     Datum name (see `proj -ld`)
+ellps     Ellipsoid name (see `proj -le`)
+init      Initialize from a named CRS
+k         Scaling factor (old name)
+k_0       Scaling factor (new name)
+lat_0     Latitude of origin
+lat_1     Latitude of first standard parallel
+lat_2     Latitude of second standard parallel
+lat_ts    Latitude of true scale
+lon_0     Central meridian
+lonc      ? Longitude used with Oblique Mercator and possibly a few others
+lon_wrap  Center longitude to use for wrapping (see below)
+nadgrids  Filename of NTv2 grid file to use for datum transforms (see below)
+no_defs   Don't use the /usr/share/proj/proj_def.dat defaults file
+over      Allow longitude output outside -180 to 180 range, disables wrapping (see below)
+pm        Alternate prime meridian (typically a city name, see below)
+proj      Projection name (see `proj -l`)
+south     Denotes southern hemisphere UTM zone
+to_meter  Multiplier to convert map units to 1.0m
+towgs84   3 or 7 term datum transform parameters (see below)
+units     meters, US survey feet, etc.
+vto_meter vertical conversion to meters.
+vunits    vertical units.
+x_0       False easting
+y_0       False northing
+zone      UTM zone
+a         Semimajor radius of the ellipsoid axis
+alpha     ? Used with Oblique Mercator and possibly a few others
+azi
+b         Semiminor radius of the ellipsoid axis
+belgium
+beta
+czech
+e         Eccentricity of the ellipsoid = sqrt(1 - b^2/a^2) = sqrt( f*(2-f) )
+ellps     Ellipsoid name (see `proj -le`)
+es        Eccentricity of the ellipsoid squared
+f         Flattening of the ellipsoid (often presented as an inverse, e.g. 1/298)
+gamma
+geoc
+guam
+h
+k         Scaling factor (old name)
+K
+k_0       Scaling factor (new name)
+lat_0     Latitude of origin
+lat_1     Latitude of first standard parallel
+lat_2     Latitude of second standard parallel
+lat_b
+lat_t
+lat_ts    Latitude of true scale
+lon_0     Central meridian
+lon_1
+lon_2
+lonc      ? Longitude used with Oblique Mercator and possibly a few others
+lsat
+m
+M
+n
+no_cut
+no_off
+no_rot
+ns
+o_alpha
+o_lat_1
+o_lat_2
+o_lat_c
+o_lat_p
+o_lon_1
+o_lon_2
+o_lon_c
+o_lon_p
+o_proj
+over
+p
+path
+proj      Projection name (see `proj -l`)
+q
+R
+R_a
+R_A       Compute radius such that the area of the sphere is the same as the area of the ellipsoid
+rf        Reciprocal of the ellipsoid flattening term (e.g. 298)
+R_g
+R_h
+R_lat_a
+R_lat_g
+rot
+R_V
+s
+south     Denotes southern hemisphere UTM zone
+sym
+t
+theta
+tilt
+to_meter  Multiplier to convert map units to 1.0m
+units     meters, US survey feet, etc.
+vopt
+W
+westo
+x_0       False easting
+y_0       False northing
+zone      UTM zone
"""

with env_ctx_if_needed():
    _lines = filter(lambda x: len(x) > 1, _param_data.split("\n"))
    all_proj_keys = list(set(line.split()[0].lstrip("+").strip()
                             for line in _lines)) + ['no_mayo']
