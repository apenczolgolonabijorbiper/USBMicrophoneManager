<#
MMDevice endpoint enumeration and audio peak metering.
#>

Set-StrictMode -Version 2.0

function Initialize-AudioEndpointApi {
    <# Loads a small .NET interop type used to call the Windows Core Audio MMDevice API from PowerShell. #>
    param([scriptblock]$Logger)

    if ('USBMicrophoneManager.AudioApi' -as [type]) { return }

    $source = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace USBMicrophoneManager {
    public sealed class EndpointInfo {
        public string Id;
        public string Name;
        public string DeviceFriendlyName;
        public string InterfaceFriendlyName;
        public string ContainerId;
        public string State;
        public string Guid;
    }

    public static class AudioApi {
        private const int STGM_READ = 0;
        private static readonly Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        private static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY(new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"), 14);
        private static readonly PROPERTYKEY PKEY_DeviceInterface_FriendlyName = new PROPERTYKEY(new Guid("026E516E-B814-414B-83CD-856D6FEF4822"), 2);
        private static readonly PROPERTYKEY PKEY_Device_ContainerId = new PROPERTYKEY(new Guid("8C7ED206-3F8A-4827-B3AB-AE9E1FAEFC6C"), 2);

        public static EndpointInfo[] EnumerateCaptureEndpoints() {
            List<EndpointInfo> list = new List<EndpointInfo>();
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDeviceCollection collection;
            enumerator.EnumAudioEndpoints(EDataFlow.eCapture, 15, out collection);
            int count;
            collection.GetCount(out count);
            for (int i = 0; i < count; i++) {
                IMMDevice device;
                collection.Item(i, out device);
                string id;
                device.GetId(out id);
                int state;
                device.GetState(out state);
                IPropertyStore store;
                device.OpenPropertyStore(STGM_READ, out store);

                EndpointInfo info = new EndpointInfo();
                info.Id = id;
                info.Guid = ExtractGuid(id);
                info.State = DecodeDeviceState(state);
                info.Name = ReadString(store, PKEY_Device_FriendlyName);
                info.DeviceFriendlyName = info.Name;
                info.InterfaceFriendlyName = ReadString(store, PKEY_DeviceInterface_FriendlyName);
                info.ContainerId = ReadGuidString(store, PKEY_Device_ContainerId);
                list.Add(info);

                if (store != null) Marshal.ReleaseComObject(store);
                if (device != null) Marshal.ReleaseComObject(device);
            }
            if (collection != null) Marshal.ReleaseComObject(collection);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            return list.ToArray();
        }

        public static string GetDefaultCaptureEndpointId(int role) {
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDevice device = null;
            try {
                int hr = enumerator.GetDefaultAudioEndpoint(EDataFlow.eCapture, role, out device);
                if (hr != 0 || device == null) return "";
                string id;
                hr = device.GetId(out id);
                if (hr != 0) return "";
                return id ?? "";
            }
            finally {
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }

        public static int SetDefaultCaptureEndpoint(string endpointId) {
            if (String.IsNullOrEmpty(endpointId)) return -1;
            IPolicyConfig policy = (IPolicyConfig)(new PolicyConfigClient());
            try {
                int hr = policy.SetDefaultEndpoint(endpointId, 0);
                if (hr != 0) return hr;
                return policy.SetDefaultEndpoint(endpointId, 1);
            }
            finally {
                if (policy != null) Marshal.ReleaseComObject(policy);
            }
        }

        public static int SetDefaultCaptureEndpointForRole(string endpointId, int role) {
            if (String.IsNullOrEmpty(endpointId)) return -1;
            IPolicyConfig policy = (IPolicyConfig)(new PolicyConfigClient());
            try {
                return policy.SetDefaultEndpoint(endpointId, role);
            }
            finally {
                if (policy != null) Marshal.ReleaseComObject(policy);
            }
        }

        public static float GetPeakValue(string endpointId) {
            if (String.IsNullOrEmpty(endpointId)) return 0;
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumerator());
            IMMDevice device = null;
            IAudioMeterInformation meter = null;
            try {
                int hr = enumerator.GetDevice(endpointId, out device);
                if (hr != 0 || device == null) throw new COMException("IMMDeviceEnumerator.GetDevice failed", hr);
                object obj;
                Guid iid = IID_IAudioMeterInformation;
                hr = device.Activate(ref iid, CLSCTX.CLSCTX_ALL, IntPtr.Zero, out obj);
                if (hr != 0 || obj == null) throw new COMException("IMMDevice.Activate(IAudioMeterInformation) failed", hr);
                meter = (IAudioMeterInformation)obj;
                float value;
                hr = meter.GetPeakValue(out value);
                if (hr != 0) throw new COMException("IAudioMeterInformation.GetPeakValue failed", hr);
                if (value < 0) value = 0;
                if (value > 1) value = 1;
                return value;
            }
            finally {
                if (meter != null) Marshal.ReleaseComObject(meter);
                if (device != null) Marshal.ReleaseComObject(device);
                if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            }
        }

        private static string ExtractGuid(string id) {
            if (String.IsNullOrEmpty(id)) return "";
            int open = id.LastIndexOf('{');
            int close = id.LastIndexOf('}');
            if (open >= 0 && close > open) return id.Substring(open, close - open + 1).ToUpperInvariant();
            return id;
        }

        private static string DecodeDeviceState(int state) {
            if ((state & 1) == 1) return "ACTIVE";
            if ((state & 2) == 2) return "DISABLED";
            if ((state & 4) == 4) return "NOTPRESENT";
            if ((state & 8) == 8) return "UNPLUGGED";
            return state.ToString();
        }

        private static string ReadString(IPropertyStore store, PROPERTYKEY key) {
            PROPVARIANT value;
            PropVariantInit(out value);
            try {
                store.GetValue(ref key, out value);
                if (value.vt == 31 && value.pointerValue != IntPtr.Zero) {
                    return Marshal.PtrToStringUni(value.pointerValue);
                }
                return "";
            }
            finally {
                PropVariantClear(ref value);
            }
        }

        private static string ReadGuidString(IPropertyStore store, PROPERTYKEY key) {
            PROPVARIANT value;
            PropVariantInit(out value);
            try {
                store.GetValue(ref key, out value);
                if (value.vt == 72 && value.pointerValue != IntPtr.Zero) {
                    byte[] bytes = new byte[16];
                    Marshal.Copy(value.pointerValue, bytes, 0, 16);
                    return new Guid(bytes).ToString("B").ToUpperInvariant();
                }
                if (value.vt == 31 && value.pointerValue != IntPtr.Zero) {
                    return Marshal.PtrToStringUni(value.pointerValue).ToUpperInvariant();
                }
                return "";
            }
            finally {
                PropVariantClear(ref value);
            }
        }

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PROPVARIANT pvar);

        [DllImport("ole32.dll")]
        private static extern int PropVariantInit(out PROPVARIANT pvar);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumerator { }

    public enum EDataFlow { eRender = 0, eCapture = 1, eAll = 2 }
    [Flags] public enum CLSCTX { CLSCTX_INPROC_SERVER = 0x1, CLSCTX_INPROC_HANDLER = 0x2, CLSCTX_LOCAL_SERVER = 0x4, CLSCTX_REMOTE_SERVER = 0x10, CLSCTX_ALL = 0x17 }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public int pid;
        public PROPERTYKEY(Guid fmtid, int pid) { this.fmtid = fmtid; this.pid = pid; }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr pointerValue;
        public int intValue2;
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    public interface IMMDeviceEnumerator {
        [PreserveSig]
        int EnumAudioEndpoints(EDataFlow dataFlow, int dwStateMask, [MarshalAs(UnmanagedType.Interface)] out IMMDeviceCollection ppDevices);
        [PreserveSig]
        int GetDefaultAudioEndpoint(EDataFlow dataFlow, int role, [MarshalAs(UnmanagedType.Interface)] out IMMDevice ppEndpoint);
        [PreserveSig]
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, [MarshalAs(UnmanagedType.Interface)] out IMMDevice ppDevice);
        [PreserveSig]
        int RegisterEndpointNotificationCallback(IntPtr pClient);
        [PreserveSig]
        int UnregisterEndpointNotificationCallback(IntPtr pClient);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0BD7A1BE-7A1A-44DB-8397-C0ACCD9A061B")]
    public interface IMMDeviceCollection {
        [PreserveSig]
        int GetCount(out int pcDevices);
        [PreserveSig]
        int Item(int nDevice, [MarshalAs(UnmanagedType.Interface)] out IMMDevice ppDevice);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    public interface IMMDevice {
        [PreserveSig]
        int Activate(ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig]
        int OpenPropertyStore(int stgmAccess, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ppProperties);
        [PreserveSig]
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        [PreserveSig]
        int GetState(out int pdwState);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    public interface IPropertyStore {
        [PreserveSig]
        int GetCount(out int cProps);
        [PreserveSig]
        int GetAt(int iProp, out PROPERTYKEY pkey);
        [PreserveSig]
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        [PreserveSig]
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT propvar);
        [PreserveSig]
        int Commit();
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
    public interface IAudioMeterInformation {
        [PreserveSig]
        int GetPeakValue(out float pfPeak);
        [PreserveSig]
        int GetMeteringChannelCount(out int pnChannelCount);
        [PreserveSig]
        int GetChannelsPeakValues(int u32ChannelCount, [Out] float[] afPeakValues);
        [PreserveSig]
        int QueryHardwareSupport(out int pdwHardwareSupportMask);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    public class PolicyConfigClient { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
    public interface IPolicyConfig {
        [PreserveSig] int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr format);
        [PreserveSig] int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultFormat, IntPtr format);
        [PreserveSig] int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId);
        [PreserveSig] int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr endpointFormat, IntPtr mixFormat);
        [PreserveSig] int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int defaultPeriod, IntPtr period, IntPtr minimumPeriod);
        [PreserveSig] int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr period);
        [PreserveSig] int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr mode);
        [PreserveSig] int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr key, IntPtr value);
        [PreserveSig] int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string deviceId, IntPtr key, IntPtr value);
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
        [PreserveSig] int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int visible);
    }
}
"@

    try {
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        Write-AppLog -Message 'MMDevice API initialized.' -Level INFO -Logger $Logger
    }
    catch {
        Write-AppLog -Message ("MMDevice API initialization failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
}

function Get-CaptureAudioEndpoints {
    <# Returns all capture MMDevice endpoints using the fast MMDevices registry path. #>
    param([scriptblock]$Logger)

    return @(Get-CaptureAudioEndpointsFromRegistry -Logger $Logger)
}

function Get-DefaultCaptureAudioEndpointId {
    <# Returns the Windows default capture endpoint for the normal console role. #>
    param(
        [scriptblock]$Logger,
        [switch]$Quiet
    )

    Initialize-AudioEndpointApi -Logger $Logger
    if (-not ('USBMicrophoneManager.AudioApi' -as [type])) { return '' }

    try {
        return ConvertTo-PlainString ([USBMicrophoneManager.AudioApi]::GetDefaultCaptureEndpointId(0))
    }
    catch {
        if (-not $Quiet) {
            Write-AppLog -Message ("Default capture endpoint lookup failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
        }
        return ''
    }
}

function Get-DefaultCommunicationsCaptureAudioEndpointId {
    <# Returns the Windows default capture endpoint for communications applications. #>
    param(
        [scriptblock]$Logger,
        [switch]$Quiet
    )

    Initialize-AudioEndpointApi -Logger $Logger
    if (-not ('USBMicrophoneManager.AudioApi' -as [type])) { return '' }

    try {
        return ConvertTo-PlainString ([USBMicrophoneManager.AudioApi]::GetDefaultCaptureEndpointId(2))
    }
    catch {
        if (-not $Quiet) {
            Write-AppLog -Message ("Default communications capture endpoint lookup failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
        }
        return ''
    }
}

function Set-DefaultCaptureAudioEndpoint {
    <# Sets a capture endpoint as the normal Windows default for console and multimedia applications. #>
    param(
        [Parameter(Mandatory=$true)][string]$EndpointId,
        [scriptblock]$Logger
    )

    Initialize-AudioEndpointApi -Logger $Logger
    if (-not ('USBMicrophoneManager.AudioApi' -as [type])) { return $false }

    try {
        $result = [USBMicrophoneManager.AudioApi]::SetDefaultCaptureEndpoint($EndpointId)
        if ($result -ne 0) {
            throw (New-Object System.Runtime.InteropServices.COMException('Setting the default capture endpoint failed.', $result))
        }
        Write-AppLog -Message ("Default recording endpoint changed to {0}." -f $EndpointId) -Level DEVICE -Logger $Logger
        return $true
    }
    catch {
        Write-AppLog -Message ("Changing the default recording endpoint failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function Set-DefaultCommunicationsCaptureAudioEndpoint {
    <# Sets a capture endpoint as the Windows default for communications applications. #>
    param(
        [Parameter(Mandatory=$true)][string]$EndpointId,
        [scriptblock]$Logger
    )

    Initialize-AudioEndpointApi -Logger $Logger
    if (-not ('USBMicrophoneManager.AudioApi' -as [type])) { return $false }

    try {
        $result = [USBMicrophoneManager.AudioApi]::SetDefaultCaptureEndpointForRole($EndpointId, 2)
        if ($result -ne 0) {
            throw (New-Object System.Runtime.InteropServices.COMException('Setting the default communications capture endpoint failed.', $result))
        }
        Write-AppLog -Message ("Default communications recording endpoint changed to {0}." -f $EndpointId) -Level DEVICE -Logger $Logger
        return $true
    }
    catch {
        Write-AppLog -Message ("Changing the default communications recording endpoint failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        return $false
    }
}

function Get-CaptureAudioEndpointsFromRegistry {
    <# Enumerates capture endpoint metadata from the MMDevices registry tree as a fallback to COM collection enumeration. #>
    param(
        [scriptblock]$Logger,
        [switch]$Quiet
    )

    $basePath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
    $items = New-Object System.Collections.Generic.List[object]
    try {
        if (-not (Test-Path -LiteralPath $basePath)) { return @() }
        foreach ($key in Get-ChildItem -LiteralPath $basePath -ErrorAction Stop) {
            try {
                $guid = $key.PSChildName
                $propertiesPath = Join-Path $key.PSPath 'Properties'
                $props = $null
                if (Test-Path -LiteralPath $propertiesPath) {
                    $props = Get-ItemProperty -LiteralPath $propertiesPath -ErrorAction SilentlyContinue
                }

                $friendly = ''
                $interfaceName = ''
                $containerId = ''
                $pnpInstanceId = ''
                if ($props) {
                    $friendly = Convert-RegistryEndpointValue (Get-ObjectPropertyValue -Object $props -Name '{a45c254e-df1c-4efd-8020-67d146a850e0},2' -Default '')
                    if ([string]::IsNullOrWhiteSpace($friendly)) {
                        $friendly = Convert-RegistryEndpointValue (Get-ObjectPropertyValue -Object $props -Name '{a45c254e-df1c-4efd-8020-67d146a850e0},14' -Default '')
                    }
                    $interfaceName = Convert-RegistryEndpointValue (Get-ObjectPropertyValue -Object $props -Name '{b3f8fa53-0004-438e-9003-51a46e139bfc},6' -Default '')
                    if ([string]::IsNullOrWhiteSpace($interfaceName)) {
                        $interfaceName = Convert-RegistryEndpointValue (Get-ObjectPropertyValue -Object $props -Name '{026e516e-b814-414b-83cd-856d6fef4822},2' -Default '')
                    }
                    $containerId = Convert-RegistryEndpointGuid (Get-ObjectPropertyValue -Object $props -Name '{8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c},2' -Default '')
                    $pnpInstanceId = Convert-RegistryEndpointValue (Get-ObjectPropertyValue -Object $props -Name '{b3f8fa53-0004-438e-9003-51a46e139bfc},2' -Default '')
                }

                $stateValue = ''
                try {
                    $keyProps = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                    $stateValue = ConvertTo-PlainString (Get-ObjectPropertyValue -Object $keyProps -Name 'DeviceState' -Default '')
                }
                catch { }

                $endpointId = "{0.0.1.00000000}.$guid"
                $items.Add([pscustomobject]@{
                    Id = $endpointId
                    Name = $friendly
                    DeviceFriendlyName = $friendly
                    InterfaceFriendlyName = $interfaceName
                    ContainerId = $containerId
                    PnpInstanceId = $pnpInstanceId
                    State = Convert-RegistryDeviceState -StateValue $stateValue
                    Guid = $guid.ToUpperInvariant()
                })
            }
            catch {
                Write-AppLog -Message ("Registry endpoint parsing failed: {0}" -f $_.Exception.Message) -Level WARN -Logger $Logger
            }
        }
        if (-not $Quiet) {
            Write-AppLog -Message ("Registry endpoint scan returned {0} capture endpoint(s)." -f $items.Count) -Level INFO -Logger $Logger
        }
    }
    catch {
        Write-AppLog -Message ("Registry endpoint fallback failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
    }
    return $items.ToArray()
}

function Convert-RegistryDeviceState {
    <# Converts an MMDevices DeviceState integer to a readable endpoint state. #>
    param([string]$StateValue)

    switch ($StateValue) {
        '1' { return 'ACTIVE' }
        '2' { return 'DISABLED' }
        '4' { return 'NOTPRESENT' }
        '8' { return 'UNPLUGGED' }
        default {
            if ([string]::IsNullOrWhiteSpace($StateValue)) { return '' }
            return $StateValue
        }
    }
}

function Convert-RegistryEndpointValue {
    <# Converts MMDevices registry values to readable strings, including byte arrays when Windows stores DEVPROP data. #>
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    $bytes = ConvertTo-ByteArrayIfPossible -Value $Value
    if ($bytes) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes).Trim([char]0)
        if ($text -match '[\p{L}\p{N}\\{]') { return $text }
        return (($bytes | ForEach-Object { $_.ToString() }) -join '; ')
    }
    return ConvertTo-PlainString $Value
}

function Convert-RegistryEndpointGuid {
    <# Converts a DEVPROP GUID registry byte array to a standard brace-wrapped GUID string. #>
    param([object]$Value)

    $bytes = ConvertTo-ByteArrayIfPossible -Value $Value
    if ($bytes) {
        try {
            if ($bytes.Count -ge 24) {
                $guidBytes = New-Object byte[] 16
                [Array]::Copy($bytes, 8, $guidBytes, 0, 16)
                return ([guid]::new($guidBytes)).ToString('B').ToUpperInvariant()
            }
            if ($bytes.Count -eq 16) {
                return ([guid]::new($bytes)).ToString('B').ToUpperInvariant()
            }
        }
        catch { }
    }
    return (Convert-RegistryEndpointValue $Value).ToUpperInvariant()
}

function ConvertTo-ByteArrayIfPossible {
    <# Converts byte-like registry arrays to a real byte[] for decoding. #>
    param([object]$Value)

    if ($Value -is [byte[]]) { return $Value }
    if ($Value -is [array] -and $Value.Count -gt 0) {
        try {
            $bytes = New-Object byte[] $Value.Count
            for ($i = 0; $i -lt $Value.Count; $i++) {
                $bytes[$i] = [byte]$Value[$i]
            }
            return $bytes
        }
        catch { return $null }
    }
    return $null
}

function Get-AudioEndpointPeak {
    <# Reads the current peak level for a capture endpoint without recording audio. #>
    param(
        [string]$EndpointId,
        [scriptblock]$Logger,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($EndpointId)) { return 0.0 }
    Initialize-AudioEndpointApi -Logger $Logger
    try {
        return [double]([USBMicrophoneManager.AudioApi]::GetPeakValue($EndpointId))
    }
    catch {
        if (-not $Quiet) {
            Write-AppLog -Message ("Audio meter read failed: {0}" -f $_.Exception.Message) -Level ERROR -Logger $Logger
        }
        return 0.0
    }
}
