unit DFMJSON;

interface

uses
    System.Classes
  , System.JSON
  , System.Generics.Collections
  ;

function Dfm2JSON(dfm: TStream): TJSONObject; overload;
function Dfm2JSON(const filename: string): TJSONObject; overload;
function DfmBin2JSON(dfm: TStream): TJSONObject; overload;
function DfmBin2JSON(const filename: string): TJSONObject; overload;

procedure SaveJSON2Dfm(json: TJSONObject; const filename: string);
function JSON2Dfm(json: TJSONObject): string;

implementation
uses
  System.SysUtils,
  System.StrUtils,
  System.RTLConsts,
  System.IOUtils,
  Vcl.Clipbrd;

function ConvertOrderModifier(parser: TParser): Integer;
begin
  Result := -1;
  if Parser.Token = '[' then
  begin
    Parser.NextToken;
    Parser.CheckToken(toInteger);
    Result := Parser.TokenInt;
    Parser.NextToken;
    Parser.CheckToken(']');
    Parser.NextToken;
  end;
end;

function ConvertHeader(parser: TParser; IsInherited, IsInline: Boolean): TJSONObject;
var
  ClassName, ObjectName: string;
  Flags: TFilerFlags;
  Position: Integer;
begin
  Parser.CheckToken(toSymbol);
  ClassName := Parser.TokenString;
  ObjectName := '';
  if Parser.NextToken = ':' then
  begin
    Parser.NextToken;
    Parser.CheckToken(toSymbol);
    ObjectName := ClassName;
    ClassName := Parser.TokenString;
    Parser.NextToken;
  end;
  Flags := [];
  Position := ConvertOrderModifier(parser);
  result := TJSONObject.Create;
  try
    if IsInherited then
      result.AddPair('$Inherited', TJSONTrue.Create);
    if IsInline then
      result.AddPair('$Inline', TJSONTrue.Create);
    if Position >= 0 then
      result.AddPair('$ChildPos', TJSONNumber.Create(Position));
    result.AddPair('$Class', ClassName);
    if ObjectName <> '' then
      result.AddPair('$Name', ObjectName);
  except
    result.Free;
    raise;
  end;
end;

procedure ConvertProperty(parser: TParser; obj: TJSONObject); forward;

function ConvertValue(parser: TParser): TJSONValue;
var
  Order: Integer;
  arr: TJSONArray;
  sub: TJSONObject;
  TokenStr: string;

  function CombineString: String;
  begin
    Result := Parser.TokenWideString;
    while Parser.NextToken = '+' do
    begin
      Parser.NextToken;
      if not CharInSet(Parser.Token, [System.Classes.toString, toWString]) then
        Parser.CheckToken(System.Classes.toString);
      Result := Result + Parser.TokenWideString;
    end;
  end;

begin
  if CharInSet(Parser.Token, [System.Classes.toString, toWString]) then
  begin
    result := TJSONString.Create(QuotedStr(CombineString))
  end
  else
  begin
    case Parser.Token of
      toSymbol:
      begin
        tokenStr := Parser.TokenComponentIdent;
        if tokenStr = 'True' then
          result := TJsonTrue.Create
        else if tokenStr = 'False' then
          Result := TJsonFalse.Create
        else result := TJsonString.Create(Parser.TokenComponentIdent);
      end;
      toInteger:
      begin
        result := TJsonNumber.Create(Parser.TokenInt)
      end;
      toFloat:
      begin
        result := TJSONObject.Create;
        if parser.FloatType = #0 then
           TJSONObject(result).AddPair('$float', TJSONNull.Create) //null
        else TJSONObject(result).AddPair('$float', TJsonNumber.Create(Parser.FloatType));
        TJSONObject(result).AddPair('value', TJsonNumber.Create(Parser.TokenFloat));
      end;
      '[':
      begin
        result := TJSONObject.Create;
        TJSONObject(result).AddPair('$set', TJsonTrue.Create);
        arr := TJSONArray.Create;
        Parser.NextToken;

        if Parser.Token <> ']' then
          while True do
          begin
            TokenStr := Parser.TokenString;
            case Parser.Token of
              toInteger: begin end;
              System.Classes.toString,toWString: TokenStr := '#' + IntToStr(Ord(TokenStr.Chars[0]));
            else
              Parser.CheckToken(toSymbol);
            end;
            arr.Add(TokenStr);
            if Parser.NextToken = ']' then Break;
            Parser.CheckToken(',');
            Parser.NextToken;
          end;
        TJSONObject(result).AddPair('value', arr);
      end;
      '(':
      begin
        Parser.NextToken;
        result := TJSONArray.Create;
        while Parser.Token <> ')' do
           TJSONArray(result).AddElement(ConvertValue(parser));
      end;
      '{':
      begin
        Parser.NextToken;
        result := TJSONObject.Create;
        TJSONObject(result).AddPair('$hex', TJSONTrue.Create);
        tokenStr := '';
        while Parser.Token <> '}' do
        begin
           tokenStr := tokenStr + parser.TokenString;
           parser.NextToken;
        end;
        TJSONObject(result).AddPair('value', tokenStr);
      end;
      '<':
      begin
        Parser.NextToken;
        result := TJSONObject.Create;
        TJSONObject(result).AddPair('$collection', TJSONTrue.Create);
        arr := TJSONArray.Create;
        while Parser.Token <> '>' do
        begin
          Parser.CheckTokenSymbol('item');
          Parser.NextToken;
          Order := ConvertOrderModifier(parser);
          sub := TJSONObject.Create;
          if Order <> -1 then
             sub.AddPair('$order', TJSONNumber.Create(order));
          while not Parser.TokenSymbolIs('end') do
             ConvertProperty(parser, sub);
          arr.Add(sub);
          Parser.NextToken;
        end;
        TJSONObject(result).AddPair('values', arr);
      end;
      else begin
        Parser.Error(SInvalidProperty);
        result :=  nil;
      end;
    end;
    Parser.NextToken;
  end;
end;

procedure ConvertProperty(parser: TParser; obj: TJSONObject);
var
  PropName: string;
begin
  Parser.CheckToken(toSymbol);
  PropName := Parser.TokenString;
  Parser.NextToken;
  while Parser.Token = '.' do
  begin
    Parser.NextToken;
    Parser.CheckToken(toSymbol);
    PropName := PropName + '.' + Parser.TokenString;
    Parser.NextToken;
  end;
  Parser.CheckToken('=');
  Parser.NextToken;
  obj.AddPair(propName, ConvertValue(parser));
end;

function ConvertObject(parser: TParser): TJSONObject;
var
  InheritedObject: Boolean;
  InlineObject: Boolean;
  children: TJSONArray;
begin
  InheritedObject := False;
  InlineObject := False;
  if Parser.TokenSymbolIs('INHERITED') then
    InheritedObject := True
  else if Parser.TokenSymbolIs('INLINE') then
    InlineObject := True
  else
    Parser.CheckTokenSymbol('OBJECT');
  Parser.NextToken;
  result := ConvertHeader(parser, InheritedObject, InlineObject);
  while not Parser.TokenSymbolIs('END') and
    not Parser.TokenSymbolIs('OBJECT') and
    not Parser.TokenSymbolIs('INHERITED') and
    not Parser.TokenSymbolIs('INLINE') do
    ConvertProperty(parser, result);
  children := TJSONArray.Create;
  while not Parser.TokenSymbolIs('END') do
     children.Add(ConvertObject(parser));
  result.AddPair('$Children', children);
  Parser.NextToken;
end;

function Dfm2JSON(dfm: TStream): TJSONObject;
var
  parser: TParser;
begin
  parser := TParser.Create(dfm);
  try
    result := ConvertObject(parser);
  finally
    parser.Free;
  end;
end;

function Dfm2JSON(const filename: string): TJSONObject;
var
  stream: TStringStream;
begin
  stream := TStringStream.Create(TFile.ReadAllText(filename), TEncoding.UTF8);
  try
    result := Dfm2JSON(stream);
  finally
    stream.Free;
  end;
end;

function DfmBin2JSON(dfm: TStream): TJSONObject;
var
   outStream: TStringStream;
begin
  outStream := TStringStream.Create();
  try
    System.Classes.ObjectBinaryToText(dfm, outStream);
    result := Dfm2JSON(outStream);
  finally
    outStream.Free;
  end;
end;

function DfmBin2JSON(const filename: string): TJSONObject;
var
  stream: TFileStream;
begin
  stream := TFile.OpenRead(filename);
  try
    result := DfmBin2JSON(stream);
  finally
    stream.Free;
  end;
end;

procedure SaveJSON2Dfm(json: TJSONObject; const filename: string);
begin
  TFile.WriteAllText(filename, JSON2DFM(json));
end;

//------------------------------------------------------------------------------

function IndentStr(depth: integer): string;
begin
  result := StringOfChar(' ', depth * 2);
end;

procedure WriteJSONObject(json: TJSONObject; sl: TStringList; indent: integer); forward;
procedure WriteJSONProperty(const name: string; value: TJSONValue; sl: TStringList; indent: integer); forward;

function capitalize(value: string): string;
begin
  value[1] := UpCase(value[1]);
  result := value;
end;

procedure WriteJSONArrProperty(const name: string; value: TJSONArray; sl: TStringList; indent: integer);

  function GetString(value: TJSONValue): string;
  begin
    if (value is TJSONTrue) or (value is TJSONFalse) then
      result := capitalize(value.Value)
    else
      result := value.Value;
  end;

var
  i: integer;
  line: string;
begin
  sl.Add(IndentStr(indent) + format('%s = (', [name]));
  for i := 0 to value.Count - 1 do
  begin

    line := IndentStr(indent + 1) + GetString(value.Items[i]);
    if i = value.Count - 1 then
    line := line + ')';
    sl.Add(line);
  end;
end;

procedure WriteFloatProperty(const name: string; value: TJSONObject; sl: TStringList; indent: integer);
var
  float, fValue: TJSONValue;
  num: double;
  numVal: string;
begin
  float := value.Values['$float'];
  fValue := value.Values['value'];
  num := (fValue as TJSONNumber).AsDouble;
  if (frac(num) = 0.0) and (num.ToString.IndexOfAny(['e', 'E']) = -1) then
    numVal := num.ToString + '.000000000000000000'
  else numval := num.ToString;
  { TODO -oLG : Have not yet discerned the purpose of this code, presently running fine without it }
(*
  if float.ValueType = jvtUndefined then
    sl.Add(IndentStr(indent) + format('%s = %s', [name, numVal]))
  else *)sl.Add(IndentStr(indent) + format('%s = %s', [name, numVal + float.Value]));
end;

procedure WriteSetProperty(const name: string; value: TJSONObject; sl: TStringList; indent: integer);
var
  i: integer;
  line: string;
  sub: TJSONArray;
begin
  line := '';
  sub := value.Values['value'] as TJSONArray;
  for i := 0 to sub.Count - 1 do
  begin
    if line = '' then
      line := sub.Items[i].Value
    else line := format('%s, %s', [line, sub.Items[i].Value]);
  end;
  sl.Add(IndentStr(indent) + format('%s = [%s]', [name, line]));
end;

procedure WriteHexProperty(const name: string; value: TJSONObject; sl: TStringList; indent: integer);
var
  hex, line: string;
begin
  sl.Add(IndentStr(indent) + format('%s = {', [name]));
  hex := value.Values['value'].Value;  { malkovich.Malkovich['Malkovich'].Malkovich }
  while hex <> '' do
  begin
    line := Copy(hex, 0, 64);
    delete(hex, 1, 64);
    if hex = '' then
      line := line + '}';
    sl.Add(IndentStr(indent + 1) + line);
  end;
end;

procedure WriteCollectionItem(value: TJSONObject; sl: TStringList; indent: integer);
var
  i: integer;
  name : string;
begin
  if Assigned(value.Values['$order']) then
    sl.Add(IndentStr(indent) + format('item [%d]', [(value.Values['$order'] as TJsonNumber).AsInt]))
  else sl.Add(IndentStr(indent) + 'item');
  for i := 0 to value.Count - 1 do begin
    name := value.Pairs[i].JsonString.Value;
    if not name.StartsWith('$') then
      WriteJSONProperty(name, value.Values[name], sl, indent + 1);
  end;
  sl.Add(IndentStr(indent) + 'end');
end;

procedure WriteCollection(const name: string; value: TJSONObject; sl: TStringList; indent: integer);
var
  values: TJSONArray;
  sub: TJSONValue;
begin
  sl.Add(IndentStr(indent) + format('%s = <', [name]));
  values := value.Values['values'] as TJSONArray;
  for sub in values do
    WriteCollectionItem(sub as TJSONObject, sl, indent + 1);
  sl[sl.Count - 1] := sl[sl.Count - 1] + '>';
end;

procedure WriteJSONObjProperty(const name: string; value: TJSONObject; sl: TStringList; indent: integer);
begin
  if assigned(value.Values['$float']) then
    WriteFloatProperty(name, value, sl, indent)
  else if assigned(value.Values['$set']) then
    WriteSetProperty(name, value, sl, indent)
  else if assigned(value.Values['$hex']) then
    WriteHexProperty(name, value, sl, indent)
  else if assigned(value.Values['$collection']) then
    WriteCollection(name, value, sl, indent)
  else
    asm int 3 end;
end;

function StringNeedsWork(const str: string): boolean;
begin
  result := (str.Length > 66) or (str.IndexOfAny([#13, #10]) > -1);
end;

function DfmQuotedStr(const value: string): string;
const separators: array[0..2] of string = (#13#10, #13, #10);
var
  lines: TArray<string>;
  i: integer;
begin
  lines := value.Split(separators, TStringSplitOptions.None);
  for i := 0 to high(lines) do
    if lines[i] <> '' then
      lines[i] := QuotedStr(lines[i]);
  result := String.join('#13', lines);
end;

procedure WriteStringProperty(const name: string; value: TJSONValue; sl: TStringList; indent: integer);
var
  str, sub: string;
begin
  str := value.Value;
  if str.StartsWith('''') and StringNeedsWork(str) then //66 = 64 limit + 2 quotes
  begin
    str := AnsiDequotedStr(str, '''');
    sl.Add(IndentStr(indent) + format('%s = ', [name]));
    while str.Length > 0 do
    begin
      sub := DfmQuotedStr(Copy(str, 0, 64));
      delete(str, 1, 64);
      if str <> '' then
        sub := sub + ' +';
      sl.Add(IndentStr(indent + 1) + sub);
    end;
  end
  else sl.Add(IndentStr(indent) + format('%s = %s', [name, str]));
end;

procedure WriteJSONProperty(const name: string; value: TJSONValue; sl: TStringList; indent: integer);
begin
  if value is TJSONObject then
    WriteJSONObjProperty(name, value as TJSONObject, sl, indent)
  else if value is TJSONArray then
    WriteJSONArrProperty(name, value as TJSONArray, sl, indent)
  else if value is TJSONString then
    WritestringProperty(name, value, sl, indent)
  else if value is TJSONNumber then
    sl.Add(IndentStr(indent) + format('%s = %s', [name, value.Value]))
  else if (value is TJSONTrue) or (value is TJSONFalse) then
    sl.Add(IndentStr(indent) + format('%s = %s', [name, capitalize(value.Value)]))
  else
    assert(False);
end;

procedure WriteJSONProperties(json: TJSONObject; sl: TStringList; indent: integer);
var
  i: integer;
  name: string;
  children : TJSONArray;
  child: TJSONValue;
begin
  for i := 0 to json.Count - 1 do
  begin
    name := json.Pairs[i].JsonString.Value;
    if not name.StartsWith('$') then
      WriteJSONProperty(name, json.Values[name], sl, indent);
  end;

  children := json.Values['$Children'] as TJSONArray;
  if Assigned(children) then
    for child in children do
      WriteJSONObject(child as TJSONObject, sl, indent);
end;

procedure WriteJSONObject(json: TJSONObject; sl: TStringList; indent: integer);
var
  dfmType, name, cls, header: string;
begin
  if Assigned(json.Values['$Inherited']) then
    dfmType := 'inherited'
  else if Assigned(json.Values['$Inline']) then
    dfmType := 'inline'
  else dfmType := 'object';
  if Assigned(json.Values['$Name']) then
     name := json.Values['$Name'].Value
  else name := '';
  cls := json.Values['$Class'].Value;
  if name = '' then
    header := format('%s %s', [dfmType, cls])
  else header := format('%s %s: %s', [dfmType, name, cls]);
  if Assigned(json.Values['$ChildPos']) then
    header := format('%s [%d]', [header, (json.Values['$ChildPos'] as TJSONNumber).AsInt]);
  sl.Add(indentStr(indent) + header);
  WriteJSONProperties(json, sl, indent + 1);
  sl.add(indentStr(indent) + 'end');
end;

function JSON2Dfm(json: TJSONObject): string;
var
  sl: TStringList;
begin
  sl := TStringList.Create();
  try
    WriteJSONObject(json, sl, 0);
    result := sl.Text;
  finally
    sl.free;
  end;
end;

end.
