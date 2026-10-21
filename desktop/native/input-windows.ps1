# Dedicated input helper. Fixed source; messages arrive as JSON on stdin, never as commands.
param([switch]$Check)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class M2PInput {
 [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION u; }
 [StructLayout(LayoutKind.Explicit)] public struct UNION { [FieldOffset(0)] public MOUSE m; [FieldOffset(0)] public KEY k; }
 [StructLayout(LayoutKind.Sequential)] public struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] public struct KEY { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
 [DllImport("user32.dll",SetLastError=true)] static extern uint SendInput(uint n,INPUT[] values,int size);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 static void Emit(INPUT v){if(SendInput(1,new[]{v},Marshal.SizeOf(typeof(INPUT)))!=1)throw new Exception("Input denied");}
 public static void Mouse(uint flags,int data=0){Emit(new INPUT{type=0,u=new UNION{m=new MOUSE{flags=flags,data=unchecked((uint)data)}}});}
 public static void Key(ushort vk,bool up){Emit(new INPUT{type=1,u=new UNION{k=new KEY{vk=vk,flags=up?2u:0u}}});}
 public static void Text(string text){foreach(char c in text){Emit(new INPUT{type=1,u=new UNION{k=new KEY{scan=c,flags=4}}});Emit(new INPUT{type=1,u=new UNION{k=new KEY{scan=c,flags=6}}});}}
}
'@
if ($Check) {
 $size=[System.Runtime.InteropServices.Marshal]::SizeOf([type][M2PInput+INPUT])
 $expected=if([IntPtr]::Size -eq 8){40}else{28}
 if($size -ne $expected){throw "Wrong INPUT ABI size: $size"}
 Write-Output "PASS Windows input helper compiled; INPUT ABI $size bytes; no input emitted"
 exit 0
}
$keys=@{return=13;enter=13;tab=9;space=32;delete=8;backspace=8;forwarddelete=46;escape=27;left=37;up=38;right=39;down=40;home=36;end=35;pageup=33;pagedown=34;equal=187;minus=189;rightbracket=221;leftbracket=219;backslash=220;quote=222;semicolon=186;comma=188;slash=191;period=190;grave=192}
for($i=1;$i -le 12;$i++){$keys["f$i"]=111+$i}
$down=@(2,8,32);$up=@(4,16,64);$held=[Collections.Generic.HashSet[int]]::new()
function Release-All {foreach($b in @($held)){[M2PInput]::Mouse($up[$b])};$held.Clear()}
[Console]::OutputEncoding=[Text.UTF8Encoding]::new();[Console]::InputEncoding=[Text.UTF8Encoding]::new()
[Console]::WriteLine('READY')
try {
 while($null -ne ($line=[Console]::ReadLine())) {
  if($line.Length -gt 20000){break}
  $v=$line|ConvertFrom-Json
  switch($v.t){
   'm' {[void][M2PInput]::SetCursorPos([int]$v.x,[int]$v.y)}
   'g' {[void][M2PInput]::SetCursorPos([int]$v.x,[int]$v.y)}
   'd' {if($held.Add([int]$v.b)){[M2PInput]::Mouse($down[[int]$v.b])}}
   'u' {[M2PInput]::Mouse($up[[int]$v.b]);[void]$held.Remove([int]$v.b)}
   's' {if($v.dy){[M2PInput]::Mouse(2048,[int]$v.dy)};if($v.dx){[M2PInput]::Mouse(4096,[int]$v.dx)}}
   'txt' {[M2PInput]::Text([string]$v.s)}
   'key' {
    $mods=@();foreach($m in $v.m){$mods+=@{ctrl=17;shift=16;alt=18;cmd=91}[$m]}
    $vk=$keys[[string]$v.k];if(!$vk -and $v.k -match '^[a-z0-9]$'){$vk=[int][char]$v.k.ToUpperInvariant()}
    if($vk){try{foreach($m in $mods){[M2PInput]::Key($m,$false)};[M2PInput]::Key($vk,$false);[M2PInput]::Key($vk,$true)}finally{[array]::Reverse($mods);foreach($m in $mods){[M2PInput]::Key($m,$true)}}}
   }
   'cancel' {Release-All}
  }
 }
} finally {Release-All}
