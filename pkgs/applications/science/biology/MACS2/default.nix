{ lib, python3, fetchurl }:

python3.pkgs.buildPythonPackage rec {
  pname = "MACS2";
  version = "2.2.7.1";

  src = python3.pkgs.fetchPypi {
    inherit pname version;
    sha256 = "1rcxj943kgzs746f5jrb72x1cp4v50rk3qmad0m99a02vndscb5d";
  };

  propagatedBuildInputs = with python3.pkgs; [ numpy ];

  # To prevent ERROR: diffpeak_cmd (unittest.loader._FailedTest) for obsolete
  # function (ImportError: Failed to import test module: diffpeak_cmd)
  doCheck = false;
  pythonImportsCheck = [ "MACS2" ];

  meta = with lib; {
    description = "Model-based Analysis for ChIP-Seq";
    license = licenses.bsd3;
    maintainers = with maintainers; [ gschwartz ];
    platforms = platforms.linux;
  };
}
