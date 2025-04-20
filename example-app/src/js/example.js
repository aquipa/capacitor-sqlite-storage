import { SQLite } from 'capacitor-sqlite-storage';

window.testEcho = () => {
    const inputValue = document.getElementById("echoInput").value;
    SQLite.echo({ value: inputValue })
}
