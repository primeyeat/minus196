#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l){ if(m==WM_DESTROY){PostQuitMessage(0);return 0;} return DefWindowProcA(h,m,w,l); }
int main(void)
{
    WNDCLASSA wc = {0}; wc.lpfnWndProc = wp; wc.hInstance = GetModuleHandleA(0); wc.lpszClassName = "present11";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("present11", "present test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 400, 0, 0, wc.hInstance, 0);
    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 400; sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    ID3D11Device *dev; ID3D11DeviceContext *ctx; IDXGISwapChain *sc; D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(0, D3D_DRIVER_TYPE_HARDWARE, 0, 0, 0, 0, D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    printf("create hr=%08lx fl=%x\n", hr, fl); fflush(stdout); if (FAILED(hr)) return 1;
    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    DWORD start = GetTickCount(); int frames = 0; MSG msg;
    while (GetTickCount() - start < 14000) {
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
        ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, 0, &rtv);
        float c[4] = { 0.9f, (frames % 120) / 120.0f, 0.1f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(bb); frames++;
    }
    printf("frames=%d last hr=%08lx\n", frames, hr); return 0;
}
