#define COBJMACROS
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
static LRESULT CALLBACK wp(HWND h, UINT m, WPARAM w, LPARAM l) { if (m == WM_DESTROY) PostQuitMessage(0); return DefWindowProcA(h, m, w, l); }
#define CHECK(what) do { printf("%s hr=%08lx\n", what, hr); fflush(stdout); if (FAILED(hr)) return 1; } while (0)
int main(void) {
    WNDCLASSA wc = {0}; wc.lpfnWndProc = wp; wc.hInstance = GetModuleHandleA(0); wc.lpszClassName = "p12";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("p12", "present12 test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 400, 0, 0, wc.hInstance, 0);
    ID3D12Device *dev; HRESULT hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev); CHECK("device");
    D3D12_FEATURE_DATA_FEATURE_LEVELS fl = {0}; D3D_FEATURE_LEVEL lv[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_12_0, D3D_FEATURE_LEVEL_12_1, D3D_FEATURE_LEVEL_12_2};
    fl.NumFeatureLevels = 4; fl.pFeatureLevelsRequested = lv;
    if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof fl))) printf("max feature level %x\n", fl.MaxSupportedFeatureLevel);
    D3D12_COMMAND_QUEUE_DESC qd = {0}; qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue *q; hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q); CHECK("queue");
    IDXGIFactory4 *f; hr = CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&f); CHECK("factory");
    DXGI_SWAP_CHAIN_DESC1 sd = {0}; sd.Width = 640; sd.Height = 400; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *sc1; hr = IDXGIFactory4_CreateSwapChainForHwnd(f, (IUnknown *)q, hwnd, &sd, NULL, NULL, &sc1); CHECK("swapchain");
    IDXGISwapChain3 *sc; hr = IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void **)&sc); CHECK("swapchain3");
    D3D12_DESCRIPTOR_HEAP_DESC hd = {0}; hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV; hd.NumDescriptors = 2;
    ID3D12DescriptorHeap *heap; hr = ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap); CHECK("heap");
    UINT inc = ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE base = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);
    ID3D12Resource *bb[2]; D3D12_CPU_DESCRIPTOR_HANDLE rtv[2];
    for (int i = 0; i < 2; i++) {
        hr = IDXGISwapChain3_GetBuffer(sc, i, &IID_ID3D12Resource, (void **)&bb[i]); CHECK("buffer");
        rtv[i].ptr = base.ptr + i * inc; ID3D12Device_CreateRenderTargetView(dev, bb[i], NULL, rtv[i]);
    }
    ID3D12CommandAllocator *al; hr = ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&al); CHECK("allocator");
    ID3D12GraphicsCommandList *cl; hr = ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, al, NULL, &IID_ID3D12GraphicsCommandList, (void **)&cl); CHECK("list");
    ID3D12GraphicsCommandList_Close(cl);
    ID3D12Fence *fence; hr = ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence); CHECK("fence");
    HANDLE ev = CreateEventA(0, 0, 0, 0); UINT64 fv = 0; int frames = 0; DWORD start = GetTickCount(); MSG msg;
    while (GetTickCount() - start < 14000) {
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        UINT i = IDXGISwapChain3_GetCurrentBackBufferIndex(sc);
        ID3D12CommandAllocator_Reset(al); ID3D12GraphicsCommandList_Reset(cl, al, NULL);
        D3D12_RESOURCE_BARRIER b = {0}; b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; b.Transition.pResource = bb[i];
        b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT; b.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &b);
        float c[4] = { 0.1f, (frames % 120) / 120.0f, 0.9f, 1.0f };
        ID3D12GraphicsCommandList_ClearRenderTargetView(cl, rtv[i], c, 0, NULL);
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; b.Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        ID3D12GraphicsCommandList_ResourceBarrier(cl, 1, &b);
        ID3D12GraphicsCommandList_Close(cl);
        ID3D12CommandList *lists[1] = { (ID3D12CommandList *)cl }; ID3D12CommandQueue_ExecuteCommandLists(q, 1, lists);
        hr = IDXGISwapChain3_Present(sc, 1, 0); if (FAILED(hr)) break;
        ID3D12CommandQueue_Signal(q, fence, ++fv);
        if (ID3D12Fence_GetCompletedValue(fence) < fv) { ID3D12Fence_SetEventOnCompletion(fence, fv, ev); WaitForSingleObject(ev, 2000); }
        frames++;
    }
    printf("frames=%d last hr=%08lx\n", frames, hr); return 0;
}
