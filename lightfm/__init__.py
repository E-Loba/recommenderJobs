try:
    __LIGHTFM_SETUP__
except NameError:
    from .lightfm import LightFM
#from .lightfm import LightFM

__version__ = "1.16"

__all__ = ["LightFM", "datasets", "evaluation"]
