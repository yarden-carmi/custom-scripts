pip uninstall torch
sudo apt-get update
sudo apt-get install libopenblas-base libopenmpi-dev libomp-dev
wget -O torch-2.3.0-cp310-cp310-linux_aarch64.whl https://nvidia.box.com/shared/static/mp164asf3sceb570wvjsrezk1p4ftj8t.whl
pip install torch-2.3.0-cp310-cp310-linux_aarch64.whl
rm torch-2.3.0-cp310-cp310-linux_aarch64.whl
python -c "import torch; print(torch.__version__); print(torch.cuda.is_available())"
