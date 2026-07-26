use rust_lib_talk2u::connectors::discord::DiscordBridge;

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let arguments = std::env::args().collect::<Vec<_>>();
    if arguments.len() < 3 || arguments.len() > 4 {
        eprintln!(
            "Usage: discord_bridge <talk2u_data_path> <discord_channel_id> [conversation_id]"
        );
        std::process::exit(2);
    }
    let bridge =
        DiscordBridge::from_environment(&arguments[1], &arguments[2], arguments.get(3).cloned())
            .unwrap_or_else(|error| {
                eprintln!("Discord bridge configuration error: {error}");
                std::process::exit(2);
            });
    if let Err(error) = bridge.run().await {
        eprintln!("Discord bridge stopped: {error}");
        std::process::exit(1);
    }
}
